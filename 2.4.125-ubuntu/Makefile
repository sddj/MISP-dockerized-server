VERSION=2.4.136
SRC_TAGGED_IMAGE=dcso/misp-dockerized-server:${VERSION}
DST_IMAGE=misp-server

.PHONY: build push
build:
	docker build\
	 --build-arg AUTHOR='Unit 42 Tech Team <unit42@paloaltonetworks.com>'\
	 --build-arg VENDOR='Palo Alto Networks'\
	 --build-arg VERSION=${VERSION}\
	 --build-arg BUILD_DATE=$$(date +%Y-%m-%d)\
	 --build-arg RELEASE_DATE=$$(date +%Y-%m-%d)\
	 --build-arg GIT_REPO=$$(git remote -v | grep 'origin.*fetch' | cut -f 2 | cut -d ' ' -f 1)\
	 --build-arg VCS_REF=$$(git rev-parse HEAD)\
	 -t ${SRC_TAGGED_IMAGE}\
	 .

.PHONY: patch
patch:
	cd ../../MISP && git diff -u 2.4 >../MISP-dockerized-server/2.4.125-ubuntu/files/patches.d/10-misp.patch

.PHONY: push
push: misp-server.push

%.push:
	if [ -f $$HOME/r/opt/aws/bin/activate ]; then . $$HOME/r/opt/aws/bin/activate; fi\
	&& $$(aws ecr get-login --no-include-email)\
	&& DST_TAGGED_IMAGE=$$(bin/image-repo-tag $*)\
	&& docker tag ${SRC_TAGGED_IMAGE} $$DST_TAGGED_IMAGE\
	&& docker push $$DST_TAGGED_IMAGE\
	&& echo $$DST_TAGGED_IMAGE
