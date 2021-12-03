#!/bin/bash -l
# Convert .STL files to .gcode and upload to Octoprint
#
# *** This action expects the following parameters AND environmental variables ***
# 
# entrypoint.sh [relative_path_to_stl] [relative_path_to_stl]
#
# SLICE_CFG    - Your slic3r configuration, with layer height, filament and printer settings pre-selected.
#
# *** Where to get the parameters ***
#
# SLICE_CFG - When slic3r is open (with preferred settings selected), go to File -> Export Config
# [relative_path_to_stl] - This is the path to the STL inside of your repository; ex: "kittens/large_cat_120mm.stl"
# GITHUB_TOKEN - A checkbox is available in the visual editor, but it can also be added by hand.
#
# *** Optional environmental variables that can be provided ***
#
# EXTRA_SLICER_ARGS - these are additions to the slic3r command-line; ex: --print-center 100,100
# BRANCH - the branch to operate on for queries to the API (default: master; others untested)
# UPDATE_RETRY - the number of times to retry a repository update, in case we desync between SHA grab and update
# CENTER_OF_BED - The center of the bed. This is used to figure out where to place the object.
WORKDIR="/github/workspace"

# Create a lock but wait if it is already held. 
# This and the retry system help to work around inconsistent repository operations.
# Derived from the flock(2) manual page.
echo "Launched at: $(date +%H:%M:%S:%N)"

(
flock 9 

echo "Running at: $(date +%H:%M:%S:%N)"

if [[ ! -e "${WORKDIR}/${SLICE_CFG}" || -z "${SLICE_CFG}" ]]; then
	echo -e "\n!!! ERROR: Unable to find 'SLICE_CFG: [ ${SLICE_CFG} ]' in your repository !!!"
	echo
	echo "Some possible things to look at:"
	echo "* This is a environmental variable in GitHub Actions, or 'env', and should be defined in your action like this:"
	echo -e "env = {\n"
	echo -e "\tSLICE_CFG = \"config.ini\""
	echo -e "}\n"
	echo "* The path is relative to the root of your repository: 'config.ini' or 'stls/config.ini'"
	echo

	exit 1
fi

# Attempt to determine the center of the bed, since the Slic3r CLI defaults to placing objects 
# at 100,100 (which may not be appropriate for all machines)
# Note: CENTER_OF_BED gets set to 100,100 if this fails.
if [[ -z "${CENTER_OF_BED}" ]]; then
	BEDSHAPE="$(grep bed_shape "${WORKDIR}/${SLICE_CFG}" | cut -d, -f3)"

	echo ">>> Got bed_shape from configuration file: ${BEDSHAPE}"
	# Example: 123x230
	if [[ $BEDSHAPE =~ ^[0-9]+x[0-9]+ ]]; then
		CENTER_OF_BED="$((${BEDSHAPE%x*}/2)),$((${BEDSHAPE#*x}/2))"
	fi
fi

echo ">>> Center of bed coordinates will be set to: ${CENTER_OF_BED}"

if [[ ! -z "${NOTE_TEXT}" ]]; then
    echo "Parsing STL from NOTE_TEXT ${NOTE_TEXT}"
    STL_URL="${NOTE_TEXT#*stl=}"
    echo "Parsed NOTE_TEXT STL value = ${STL_URL}"
fi

if [[ ! -z "${INPUT_STL_URL}" ]]; then
    echo "INPUT_STL_URL=${INPUT_STL_URL}"
    echo "Overriding dynamic workflow..."
    STL_URL=${INPUT_STL_URL}
    echo ">>> Manual workflow started >>>> Downloading STL from ${STL_URL}"
else
    echo ">>> Downloading STL from ${STL_URL}"
fi

if [[ ! -z "${STL_URL}" ]]; then
    STL_FILENAME="$(basename "${STL_URL}")"
    echo "STL Filename = ${STL_FILENAME}"
    curl -o ./${STL_FILENAME} ${STL_URL}
else 
    echo "No STL_URL found."
    exit 1
fi

# EXTRA_SLICER_ARGS
# This lets a user define additional arguments to Slic3r without having to fork and modify the
# command-line below. 
# These is added to the env 'EXTRA_SLICER_ARGS' in the workflow on a single line (note the lack of quoting):
# --print-center 100,100 --output-filename-format {input_filename_base}_{printer_model}.gcode
if [[ ! -z "${EXTRA_SLICER_ARGS}" ]]; then
	echo -e "Adding the following arguments to Slic3r: ${EXTRA_SLICER_ARGS}"
	IFS=' ' read -r -a EXTRA_SLICER_ARGS <<< "${EXTRA_SLICER_ARGS}"
fi

echo -e "\n>>> Processing STLs $* with ${SLICE_CFG}\n"

echo -e "\n>>> Generating STL for ${STL_FILENAME} ...\n"
if /Slic3r/slic3r-dist/slic3r \
    --no-gui \
    --load "${WORKDIR}/${SLICE_CFG}" \
    --output-filename-format '{input_filename_base}_{layer_height}mm_{filament_type[0]}_{printer_model}.gcode' \
    --output "${WORKDIR}" \
    --print-center "${CENTER_OF_BED:-100,100}" \
    "${EXTRA_SLICER_ARGS[@]}" "${WORKDIR}/${STL_FILENAME}"; then
    echo -e "\n>>> Successfully generated gcode for STL\n"
else
    exit_code=$?
    echo -e "\n!!! Failure generating STL  - rc: ${exit_code} !!!\n"
    exit ${exit_code}
fi

GENERATED_GCODE="$(basename "$(find "$WORKDIR" -name '*.gcode')")"
DEST_GCODE_FILE="${GENERATED_GCODE%.gcode}.gcode"

# Get path, including any subdirectories that the STL might belong in
# but exclude the WORKDIR
STL_DIR="$(dirname "${WORKDIR}/${STL_FILENAME}")"
GCODE_DIR="${STL_DIR#"$WORKDIR"}"

GCODE="${GCODE_DIR}/${DEST_GCODE_FILE}"
GCODE="${GCODE#/}"

echo -e "\n>>> Processing file as ${GCODE}\n"

if [[ -z "${OCTOPRINT_API_KEY}" ]]; then
	echo -e "\n!! WARNING: Unable to find your OCTOPRINT_API_KEY, skipping upload..."
else 
    if [[ -z "${OCTOPRINT_UPLOAD_URL}" ]]; then
        # Default to the docker service url if URL not provided
        OCTOPRINT_UPLOAD_URL="http://octoprint:80/api/files/local"
    fi

    if
        curl -k -H "X-Api-Key: ${OCTOPRINT_API_KEY}" \
        -F "select=false" \
        -F "print=false" \
        -F "file=@${WORKDIR}/${GCODE}" \
            "${OCTOPRINT_UPLOAD_URL}"
    then
        echo -e "\n>>> Successfully uploaded ${GCODE} to Octoprint!"
    else
        exit_code=$?
        echo "!!! Couldn't upload ${GCODE} rc: ${exit_code} !!!"
    fi
fi

echo -e "\n>>> Finished processing file\n"

rm -rf "${TMPDIR}"
#done
) 9>"$WORKDIR/slice.lock"

echo "Completed at: $(date +%H:%M:%S:%N)"