.PHONY: build setup up down logs status onion ps

build:   ## build the image
	docker compose build

setup:   ## interactive first-run wizard (prints onion + user + password)
	docker compose run --rm -it setup

up:      ## start the node (headless)
	docker compose up -d

down:    ## stop the node
	docker compose down

logs:    ## follow container logs
	docker compose logs -f node

status:  ## monerod sync status (runs in the node container — RPC is loopback-only)
	docker exec monerotor mtor status

onion:   ## print onion address + RPC login
	docker exec monerotor mtor onion

ps:
	docker compose ps
