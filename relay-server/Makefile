ADDR ?= :8787
APNS_KEY ?=
APNS_KEY_ID ?=
APNS_TEAM_ID ?=
APNS_TOPIC ?= app.rxlab.rxcodemobile
APNS_PRODUCTION ?= false
ENV_FILE ?= .env

.PHONY: run run-apns run-env encode-key tidy build docker-build docker-run clean

tidy:
	go mod tidy

run: tidy
	go run . -addr $(ADDR)

# Pass APNs config via CLI flags (key on disk).
run-apns: tidy
	go run . \
		-addr $(ADDR) \
		-apns-key $(APNS_KEY) \
		-apns-key-id $(APNS_KEY_ID) \
		-apns-team-id $(APNS_TEAM_ID) \
		-apns-topic $(APNS_TOPIC) \
		-apns-production=$(APNS_PRODUCTION)

# Pass everything (including the .p8) via env vars from $(ENV_FILE).
# The binary itself loads .env via godotenv — no shell-side sourcing needed.
# Expected variables: RELAY_ADDR, APNS_KEY_B64, APNS_KEY_ID, APNS_TEAM_ID,
# APNS_TOPIC, APNS_PRODUCTION.
run-env: tidy
	RELAY_ENV_FILE=$(ENV_FILE) go run .

# Helper: base64-encode a .p8 file for pasting into APNS_KEY_B64.
#   make encode-key KEY=./AuthKey_ABCDE12345.p8
encode-key:
	@base64 < $(KEY) | tr -d '\n'; echo

build:
	go build -o bin/rxcode-relay .

docker-build:
	docker build -t rxcode-relay .

docker-run:
	docker run --rm -p 8787:8787 rxcode-relay -addr :8787

clean:
	rm -rf bin
