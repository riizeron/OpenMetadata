#  Copyright 2021 Collate
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#  http://www.apache.org/licenses/LICENSE-2.0
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#  See the License for the specific language governing permissions and
#  limitations under the License.

# Build stage
FROM docker-dev.registry-ci.delta.sbrf.ru/ci04675739/ci04675739/sberjdk-21-runtime:java-21.0.8_002-sberlinux-9.6.0-se AS build

COPY context/openmetadata-*.tar.gz /

RUN mkdir -p /opt/openmetadata && \
    tar zxvf openmetadata-*.tar.gz -C /opt/openmetadata --strip-components 1 && \
    rm openmetadata-*.tar.gz

# Final stage
FROM docker-dev.registry-ci.delta.sbrf.ru/ci04675739/ci04675739/sberjdk-21-runtime:java-21.0.8_002-sberlinux-minimal-9.6.0-se

ADD context/SberCARootExt.crt /etc/pki/ca-trust/source/anchors/
RUN update-ca-trust

EXPOSE 8585

ARG SBEROSC_TOKEN

RUN groupadd -g 1000 openmetadata && \
    useradd -u 1000 -g openmetadata -m -s /bin/bash openmetadata

COPY --from=build /opt/openmetadata /opt/openmetadata
RUN chown -R openmetadata:openmetadata /opt/openmetadata

COPY context/openmetadata-start.sh /
RUN chmod 755 /openmetadata-start.sh


USER openmetadata

WORKDIR /opt/openmetadata
ENTRYPOINT [ "/bin/bash" ]
CMD ["/openmetadata-start.sh"]
