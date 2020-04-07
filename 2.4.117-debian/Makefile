VERSION=2.4.117

.PHONY:
build:
	docker build\
	 --build-arg VERSION=${VERSION}\
	 --build-arg MISP_TAG=${VERSION}\
	 --build-arg BUILD_DATE=$$(date +%Y-%m-%d)\
	 --build-arg RELEASE_DATE=$$(date +%Y-%m-%d)\
	 --build-arg GIT_REPO=$$(git remote -v | grep 'origin.*fetch' | cut -f 2 | cut -d ' ' -f 1)\
	 --build-arg VCS_REF=$$(git rev-parse HEAD)\
	 -t dcso/misp-dockerized-server:${VERSION}-debian\
	 .
