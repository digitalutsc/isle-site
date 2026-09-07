# Islandora Lite additions to isle-site-template.
#
# Everything that can live outside a file upstream maintains lives here, so that
# `git merge upstream/main` has as little to conflict with as possible. See LITE.md for the
# full picture, including the four upstream files that still carry a patch and why each one
# cannot be moved.
#
# Ported from digitalutsc/isle-dc @ islandora-lite-site-3.x (custom.Makefile), which is
# deprecated. Most of what the old `lite-*` targets did is already provided by this stack,
# because isle-dc drives site installation from the host Makefile while this stack does it
# inside the drupal container from an s6 oneshot. Those were deliberately NOT ported:
#
#   lite-init (the isle-dc one)  -> scripts/init.sh; there is no docker-compose.yml to generate
#   lite-finalize                -> DRUPAL_DEFAULT_INSTALL_EXISTING_CONFIG + DRUPAL_DEFAULT_PROFILE
#                                   drive the install from the container on first boot
#   lite_hydrate                 -> install.sh runs create_database -> install_site -> configure();
#                                   the configure_* helpers are replaced by the $config[...]
#                                   overrides in assets/patches/default_settings.txt
#   solr-cores                   -> the core config is baked into the drupal image and shared to
#                                   solr through the drupal-solr-config volume
#   configure_matomo_module      -> matomo was removed from the Lite site in October 2025
#   set-files-owner              -> scripts/build.sh handles permissions
#
# What did need porting now lives in: this file, docker-compose.lite.yml, and the
# lite-configure s6 oneshot under drupal/rootfs/etc/s6-overlay/.

# The main Makefile includes this file at its line 11, before defining any target, so without
# this the first target below would silently become the default goal and a bare `make` would
# run it. Make honours the last assignment and the main Makefile never sets one.
.DEFAULT_GOAL := help

.PHONY: lite-status lite-check-migrations lite-sync-site lite-sync-solr-conf
.PHONY: lite-init lite-compose-file lite-profile-ten lite-profile-eleven

# Where the Drupal site is vendored from.
LITE_SITE_OWNER ?= digitalutsc
LITE_SITE_REPO ?= islandora-lite-site
LITE_SITE_BRANCH ?= 2.x

# The two supported image pairings. ISLANDORA_TAG and FCREPO_IMAGE are not independently
# selectable: isle-buildkit 7.0 moved Solr 9 -> 10 and renamed islandora/fcrepo6 to
# islandora/fcrepo, and only search_api_solr 4.4 speaks Solr 10 while conflicting with Drupal
# core below 11.3. So Drupal 10 needs 4.3 -> Solr 9 -> the 6.x line. Always change them together.
LITE_TEN_ISLANDORA_TAG ?= 6.4.3
LITE_TEN_FCREPO_IMAGE ?= fcrepo6
LITE_ELEVEN_ISLANDORA_TAG ?= 7.0.9
LITE_ELEVEN_FCREPO_IMAGE ?= fcrepo

LITE_SOLR_CONF := drupal/rootfs/opt/solr/server/solr/default/conf

# Set a variable in .env, replacing it if present and appending if not.
# Uses the sed -i.bak form because BSD/macOS sed treats bare -i's next argument as a backup
# suffix; scripts/profile.sh's update_env uses bare -i and is GNU-only for that reason.
define lite_set_env
	if grep -Eq '^$(1)=' .env; then \
	  sed -i.bak 's|^$(1)=.*|$(1)=$(2)|' .env && rm -f .env.bak; \
	else \
	  echo '$(1)=$(2)' >> .env; \
	fi
endef

lite-compose-file: ## Recompute COMPOSE_FILE in .env (run after creating the dev override symlink)
	test -f .env || { echo "No .env yet. Run: make lite-init"; exit 1; }
	files="docker-compose.yml:docker-compose.lite.yml"; \
	if [ -e docker-compose.override.yml ]; then \
	  files="$$files:docker-compose.override.yml"; \
	  echo "Including docker-compose.override.yml (dev mode)."; \
	else \
	  echo "No docker-compose.override.yml; not including it."; \
	fi; \
	if grep -Eq '^COMPOSE_FILE=' .env; then \
	  sed -i.bak "s|^COMPOSE_FILE=.*|COMPOSE_FILE=$$files|" .env && rm -f .env.bak; \
	else \
	  echo "COMPOSE_FILE=$$files" >> .env; \
	fi
	grep '^COMPOSE_FILE=' .env

lite-profile-ten: ## Use the Drupal 10 image line (isle-buildkit 6.x, Solr 9, fcrepo6)
	test -f .env || { echo "No .env yet. Run: make lite-init"; exit 1; }
	$(call lite_set_env,ISLANDORA_TAG,$(LITE_TEN_ISLANDORA_TAG))
	$(call lite_set_env,FCREPO_IMAGE,$(LITE_TEN_FCREPO_IMAGE))
	$(MAKE) lite-compose-file
	echo "Drupal 10 line: ISLANDORA_TAG=$(LITE_TEN_ISLANDORA_TAG) FCREPO_IMAGE=$(LITE_TEN_FCREPO_IMAGE)"
	echo "Now run: make build && make up"

lite-profile-eleven: ## Use the Drupal 11 image line (isle-buildkit 7.x, Solr 10, fcrepo)
	test -f .env || { echo "No .env yet. Run: make lite-init"; exit 1; }
	$(call lite_set_env,ISLANDORA_TAG,$(LITE_ELEVEN_ISLANDORA_TAG))
	$(call lite_set_env,FCREPO_IMAGE,$(LITE_ELEVEN_FCREPO_IMAGE))
	$(MAKE) lite-compose-file
	echo "Drupal 11 line: ISLANDORA_TAG=$(LITE_ELEVEN_ISLANDORA_TAG) FCREPO_IMAGE=$(LITE_ELEVEN_FCREPO_IMAGE)"
	echo "The vendored site must be Drupal 11 too. See LITE.md."
	echo "Now run: make build && make up"

lite-init: ## Set up .env for the Lite stack, then run the stock init (use instead of `make init`)
	test -f .env || cp sample.env .env
	$(call lite_set_env,ISLANDORA_TAG,$(LITE_TEN_ISLANDORA_TAG))
	$(call lite_set_env,FCREPO_IMAGE,$(LITE_TEN_FCREPO_IMAGE))
	$(MAKE) lite-compose-file
	# scripts/init.sh only sets these when it creates .env itself, and we have just created it,
	# so set them here. They exist to survive the drupal/solr healthcheck cycle on first boot.
	$(call lite_set_env,DRUPAL_HEALTHCHECK_RETRIES,10)
	$(call lite_set_env,DRUPAL_HEALTHCHECK_START_PERIOD,1m)
	./scripts/init.sh

lite-sync-site: ## Re-vendor the Drupal site from digitalutsc/islandora-lite-site
	STARTER_SITE_OWNER=$(LITE_SITE_OWNER) \
	STARTER_SITE_REPO=$(LITE_SITE_REPO) \
	STARTER_SITE_BRANCH=$(LITE_SITE_BRANCH) \
	./scripts/overwrite-starter-site.sh
	echo ""
	echo "Vendored $(LITE_SITE_OWNER)/$(LITE_SITE_REPO)@$(LITE_SITE_BRANCH)."
	echo "Match the image line to it, then rebuild and refresh the Solr config:"
	echo "  make lite-profile-ten && make build && make up && make lite-sync-solr-conf"

lite-sync-solr-conf: ## Refresh the baked Solr config, then drop the runtime data it drags along
	./scripts/sync-solr-conf.sh
	# The core is live when sync-solr-conf.sh copies it, so Solr's runtime index data comes
	# too: segments, tlog and a write.lock. That is state, not config, and must not be tracked.
	rm -rf "$(LITE_SOLR_CONF)/data"
	grep -m1 'schema name=' "$(LITE_SOLR_CONF)/schema.xml"

lite-check-migrations: ## Check whether islandora_tags imports under the islandora tag
	docker compose exec -T drupal drush migrate:status --tag=islandora
	echo ""
	echo "islandora_tags is tagged only 'islandora_tags' in the Lite site, so it is imported"
	echo "separately by the lite-configure oneshot:"
	docker compose exec -T drupal drush migrate:status islandora_tags

lite-status: ## ISLE status, plus the Lite media tooling and the config-drift checks
	./scripts/status.sh
	echo ""
	echo "Islandora Lite media tooling:"
	docker compose exec -T drupal php -m | grep -qi '^imagick$$' \
		&& echo "  imagick     OK" || echo "  imagick     MISSING"
	docker compose exec -T drupal sh -lc 'command -v convert' >/dev/null 2>&1 \
		&& echo "  imagemagick OK" || echo "  imagemagick MISSING"
	docker compose exec -T drupal sh -lc 'command -v ffmpeg' >/dev/null 2>&1 \
		&& echo "  ffmpeg      OK" || echo "  ffmpeg      MISSING"
	docker compose exec -T drupal sh -lc 'command -v ffprobe' >/dev/null 2>&1 \
		&& echo "  ffprobe     OK" || echo "  ffprobe     MISSING"
	echo ""
	echo "Islandora Lite configuration:"
	tag=$$(grep -E '^ISLANDORA_TAG=' .env | cut -d= -f2 | tr -d '"'); \
	core=$$(grep -m1 'drupal/core-recommended' drupal/rootfs/var/www/drupal/composer.json \
	        | grep -oE '[0-9]+\.[0-9]+' | head -1); \
	case "$$tag" in \
	  6.*) want=10 ;; \
	  7.*) want=11 ;; \
	  *)   want=unknown ;; \
	esac; \
	echo "  ISLANDORA_TAG=$$tag (expects a Drupal $$want site); vendored site is Drupal $$core"; \
	if [ "$$want" != "unknown" ] && [ "$${core%%.*}" != "$$want" ]; then \
	  echo "  MISMATCH: run 'make lite-profile-ten' for Drupal 10 or 'make lite-profile-eleven' for Drupal 11"; \
	else \
	  echo "  image line and vendored site agree"; \
	fi
	if [ -e docker-compose.override.yml ] && ! grep -q 'docker-compose.override.yml' .env; then \
	  echo "  WARNING: docker-compose.override.yml exists but is not in COMPOSE_FILE, so dev mode is inactive."; \
	  echo "           Run 'make lite-compose-file' to pick it up."; \
	fi
