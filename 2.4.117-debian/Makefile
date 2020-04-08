IMAGE=dcso/misp-dockerized-server
ECR_IMAGE=366760835561.dkr.ecr.us-east-1.amazonaws.com/misp-server
VERSION=2.4.117

.PHONY: build push
build:
	docker build\
	 --build-arg VERSION=${VERSION}\
	 --build-arg MISP_TAG=${VERSION}\
	 --build-arg BUILD_DATE=$$(date +%Y-%m-%d)\
	 --build-arg RELEASE_DATE=$$(date +%Y-%m-%d)\
	 --build-arg GIT_REPO=$$(git remote -v | grep 'origin.*fetch' | cut -f 2 | cut -d ' ' -f 1)\
	 --build-arg VCS_REF=$$(git rev-parse HEAD)\
	 -t ${IMAGE}:${VERSION}-debian\
	 .

push:
	if [ -f $$HOME/r/opt/aws/bin/activate ]; then . $$HOME/r/opt/aws/bin/activate; fi\
	&& $$(aws ecr get-login --no-include-email)\
	&& TAG=$$(bin/image-tag misp-server)\
	&& docker tag ${IMAGE}:${VERSION}-debian ${ECR_IMAGE}:$$TAG\
	&& docker push ${ECR_IMAGE}:$$TAG\
	&& echo ${ECR_IMAGE}:$$TAG
