.PHONY: build setup up down logs status onion backup restore ps

build:   ## build the image
	docker compose build

setup:   ## interactive first-run wizard / restore
	docker compose run --rm -it setup

up:      ## start the node (headless)
	docker compose up -d

down:    ## stop the node
	docker compose down

logs:    ## follow container logs
	docker compose logs -f node

status:  ## monerod sync status
	docker compose run --rm -it setup mtor status

onion:   ## print onion addresses + RPC login
	docker compose run --rm -it setup mtor onion

backup:  ## make an encrypted backup
	docker compose run --rm -it setup mtor backup

restore: ## restore from FILE=path/to/backup.age
	docker compose run --rm -it setup mtor restore /data/config/$(notdir $(FILE))

ps:
	docker compose ps
