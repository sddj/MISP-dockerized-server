VERSION=2.4.117
SRC_TAGGED_IMAGE=dcso/misp-dockerized-server:${VERSION}-debian
DST_IMAGE=misp-server

.PHONY: build push
build:
	docker build\
	 --build-arg VERSION=${VERSION}\
	 --build-arg MISP_TAG=${VERSION}\
	 --build-arg BUILD_DATE=$$(date +%Y-%m-%d)\
	 --build-arg RELEASE_DATE=$$(date +%Y-%m-%d)\
	 --build-arg GIT_REPO=$$(git remote -v | grep 'origin.*fetch' | cut -f 2 | cut -d ' ' -f 1)\
	 --build-arg VCS_REF=$$(git rev-parse HEAD)\
	 -t ${SRC_TAGGED_IMAGE}\
	 .

push:
	if [ -f $$HOME/r/opt/aws/bin/activate ]; then . $$HOME/r/opt/aws/bin/activate; fi\
	&& $$(aws ecr get-login --no-include-email)\
	&& DST_TAGGED_IMAGE=$$(bin/image-repo-tag ${DST_IMAGE})\
	&& docker tag ${SRC_TAGGED_IMAGE} $$DST_TAGGED_IMAGE\
	&& docker push $$DST_TAGGED_IMAGE\
	&& echo $$DST_TAGGED_IMAGE
