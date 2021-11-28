FROM keyglitch/docker-slic3r-prusa3d:1.41.3

# LABEL "version"="1.0.0"

LABEL "com.github.actions.name"="Prusa Slic3r Action"
LABEL "com.github.actions.description"="Generate gcode from .stl files"
LABEL "com.github.actions.icon"="package"
LABEL "com.github.actions.color"="blue"

COPY entrypoint.sh /entrypoint.sh

USER root

RUN apt-get update && apt-get install -y jq curl

ENTRYPOINT ["bash","/entrypoint.sh"]