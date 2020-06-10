# We want to launch/build docker containers as our own UID, so we collect that from the environment
UID=$(shell id -u)
export UID

up: storage logs/nginx logs/pkgserver
	docker-compose up --build --remove-orphans -d

storage:
	mkdir -p $@
logs/nginx:
	mkdir -p $@
logs/pkgserver:
	mkdir -p $@

logs:
	docker-compose logs -f --tail=200
.PHONY: logs

down:
	docker-compose down --remove-orphans

destroy:
	docker-compose down -v --remove-orphans
