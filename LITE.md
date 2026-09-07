# Islandora Lite on isle-site-template

This repository is `Islandora-Devops/isle-site-template` with the Drupal site replaced by
`digitalutsc/islandora-lite-site@2.x` and the isle-buildkit image line made selectable, because
that site is Drupal 10 while the template ships pinned to a Drupal 11 pairing.

It replaces `digitalutsc/isle-dc` (branch `islandora-lite-site-3.x`), which is deprecated upstream.

## Where the customizations live

Almost everything is in files upstream does not have, so `git merge upstream/main` has very little
to conflict with:

| File | Role |
| :--- | :--- |
| `custom.Makefile` | every `lite-*` target, the image pairings, the `.env` handling |
| `docker-compose.lite.yml` | the one service image that differs between image lines |
| `drupal/rootfs/etc/s6-overlay/scripts/lite-configure.sh` | post-install configuration, run in-container |
| `drupal/rootfs/etc/s6-overlay/s6-rc.d/lite-configure/**` | the s6 wiring for it |
| `LITE.md` | this file |

**Four upstream files still carry a patch**, 22 added and 3 removed lines in total. Each is here
because it genuinely cannot live anywhere else:

| File | Size | Why it cannot move |
| :--- | :--- | :--- |
| `drupal/Dockerfile` | 7 lines | `drupal/media_thumbnails_pdf` requires `ext-imagick`, so the packages must be installed *before* `composer install` or the platform check fails. That has to be in the image build. |
| `install.sh` | 9 / 1 | See "The one irreducible patch" below. |
| `scripts/ping.sh` | 3 / 1 | `up.sh` calls it by path and its exit code is what makes `make up` fail, so a wrapper target cannot substitute. |
| `scripts/overwrite-starter-site.sh` | 3 / 1 | The repository name was hardcoded. Reimplementing the download would duplicate ~40 lines of upstream logic, including the `default_settings.txt` preservation, to avoid two lines. |

The last two are clean upstream pull requests — a macOS portability fix and a backward-compatible
generalization. Merging them upstream would take this to two patched files.

### The one irreducible patch

Upstream's `install.sh` runs `drush migrate:import --userid=1 --tag=islandora`. That option comes
from migrate_tools and does not exist in the version the Lite site pins. Unguarded under `set -e`,
it aborts the install oneshot *after* `install_site` has already populated the database. The
container then restarts, its `installed` check finds tables, it prints "Already Installed" and never
runs `configure()` again — leaving a site with no roles, no migrations and no media settings, and no
way back short of wiping the volumes. Nothing host-side or downstream can intervene earlier, so the
detection has to be in that file. The patch is four lines replacing one.

## The image pairing

`ISLANDORA_TAG` and `FCREPO_IMAGE` are **not independently selectable**, and together they decide
which Drupal major version this stack can host:

```sh
make lite-profile-ten      # isle-buildkit 6.4.3, Solr 9,  PHP 8.3, fcrepo6   <- current
make lite-profile-eleven   # isle-buildkit 7.0.9, Solr 10, PHP 8.4, fcrepo
make build && make up
```

Why Drupal 10 forces the 6.x line:

| Step | Consequence |
| :--- | :--- |
| isle-buildkit 7.0 bumped Solr 9 to 10 | the Solr server version moves with `ISLANDORA_TAG` |
| Only `search_api_solr` 4.4 generates Solr 10 config | 4.3 cannot talk to Solr 10 |
| 4.4.0 requires `drupal/core ^11.3` and conflicts with `<11.3` | it cannot be installed on Drupal 10 |
| So Drupal 10 needs `search_api_solr` 4.3, which targets Solr 9 | which means isle-buildkit 6.x |

PHP is not the constraint either way: Drupal 10.4+ supports PHP 8.4, and the 6.x line ships PHP 8.3,
which Drupal 10.6 also supports. Solr is what binds.

Only one image name differs between the lines — Fedora is `islandora/fcrepo6` in 6.x and was renamed
`islandora/fcrepo` in 7.0 — which is all `docker-compose.lite.yml` contains. That overlay is layered
in through `COMPOSE_FILE` in `.env` rather than by editing `docker-compose.yml`. Nothing in the repo
passes `-f` to `docker compose`, so every invocation honours it.

`make lite-status` warns if the configured tag and the vendored site's Drupal version disagree.

## Setting up

Use `make lite-init` **instead of `make init`**. It seeds `.env` with the Drupal 10 pairing and the
`COMPOSE_FILE` overlay before calling the stock `scripts/init.sh`, which only copies `sample.env`
when `.env` is absent. It also writes the two healthcheck values that `init.sh` would otherwise set
only for a `.env` it created; they exist to survive the drupal/solr healthcheck cycle on first boot.

```sh
make lite-init && make up
```

Plain `make init` still works but leaves the stock Drupal 11 image line against a Drupal 10 site.
`make lite-status` will say so.

### Dev mode

Setting `COMPOSE_FILE` disables Compose's automatic pickup of `docker-compose.override.yml`, so
after creating the symlink you must recompute it:

```sh
ln -s docker-compose.dev.yml docker-compose.override.yml
make lite-compose-file
```

`make lite-status` warns when the symlink exists but is missing from `COMPOSE_FILE`.

## Targets

```
make lite-init              # set up .env, then the stock init (use instead of `make init`)
make lite-profile-ten       # Drupal 10 image line
make lite-profile-eleven    # Drupal 11 image line
make lite-compose-file      # recompute COMPOSE_FILE (after creating the dev override symlink)
make lite-sync-site         # re-vendor the Drupal site
make lite-sync-solr-conf    # refresh the baked Solr config set
make lite-status            # ISLE status, media tooling, and drift checks
make lite-check-migrations  # migration status
```

The target names avoid digits on purpose: the stock `help` target's awk pattern is
`[a-zA-Z_-]+`, so a target named `lite-profile-d10` would silently not be listed, and widening that
pattern would mean patching the Makefile.

## Swapping the vendored site

```sh
make lite-sync-site   # digitalutsc/islandora-lite-site@2.x
```

Override with `LITE_SITE_OWNER`, `LITE_SITE_REPO`, `LITE_SITE_BRANCH`. The site is **vendored and
baked into the image** at `drupal/rootfs/var/www/drupal`; there is no bind-mounted `codebase/` as
there was in isle-dc.

### When the Lite site moves to Drupal 11

1. `make lite-sync-site LITE_SITE_BRANCH=<the D11 branch>`
2. `make lite-profile-eleven`
3. `make build && make up`
4. `make lite-sync-solr-conf`, then rebuild, so the baked Solr config is regenerated for the
   `search_api_solr` version that branch pins. The target prints the resulting schema stamp.
5. Re-check `make lite-check-migrations` and the `administrator` role note below.

## What happened to each isle-dc target

isle-dc drives site installation from an 800-line host Makefile. This stack does it inside the
drupal container from an s6 oneshot. Most of the `lite-*` machinery existed to fill gaps this stack
does not have.

| `isle-dc/custom.Makefile` | Here | Why |
| :--- | :--- | :--- |
| `lite-init` | `make lite-init` | Different job: `scripts/init.sh` already writes `.env`, generates secrets and certs, and builds. Ours only seeds the pairing first. There is no `docker-compose.yml` to generate. |
| `lite-finalize` → `drush si --existing-config minimal` | automatic | `DRUPAL_DEFAULT_INSTALL_EXISTING_CONFIG` and `DRUPAL_DEFAULT_PROFILE` drive the install on first boot. |
| `lite_hydrate` → settings, namespaces, `configure_jwt_module`, `configure_search_api_solr_module`, `configure_openseadragon` | automatic | `install.sh` runs `create_database` → `install_site` → the Blazegraph namespace → `configure()`. The `configure_*` helpers are replaced by the `$config[...]` overrides in `assets/patches/default_settings.txt`, which reads `/var/run/s6/container_environment/`. |
| `lite_hydrate` → `solr-cores` | `make lite-sync-solr-conf` | The core config is baked into the image and handed to solr through the `drupal-solr-config` volume. |
| `update-config-from-lite-environment` → `configure_matomo_module` | dropped | matomo was removed from the Lite site in October 2025. |
| `set-files-owner`, `chown -R nginx:nginx` | automatic | `scripts/build.sh` handles permissions; `DEVELOPMENT_ENVIRONMENT=true` remaps the uid. |
| `lite_dev` → `apk add imagemagick php83-pecl-imagick ffmpeg` | `drupal/Dockerfile` | A build layer, so the packages survive `make down && make up`. The suffix is derived from the interpreter rather than hardcoded, because the PHP version moves with the image line. |
| `lite_dev` → `git clone digitalutsc/islandora-lite-site` | `make lite-sync-site` | |
| `lite_dev` → `drush config:set media_thumbnails_video.settings ffmpeg/ffprobe` | `lite-configure.sh` | |
| `lite-finalize` → `drush user:role:add administrator admin` | `lite-configure.sh` | The stock template grants only `fedoraadmin`, and only when fcrepo is configured. |
| `run-lite-migrations` → `drush migrate:import islandora_tags` | `lite-configure.sh` | Still needed: the Lite site tags that migration only `islandora_tags`, not `islandora`, so `--tag=islandora` does not cover it. Exactly the gap isle-dc worked around. |

### The lite-configure oneshot

It runs after the stock `install` unit, so the three behaviours above happen automatically on
`make up` with no extra command. Because `install.sh` prints its completion banner on both the fresh
and the already-installed path, this unit runs on **every** container start — so everything in it is
idempotent and tolerates failure, and a problem there can never crash-loop the container.

If you add to it, keep both properties. The script needs the `#!/command/with-contenv bash` shebang
to see the container environment, and must be executable in git, since `scripts/build.sh` chmods
directories only.

## `default_settings.txt`

The Lite site ships a two-line `assets/patches/default_settings.txt`, because isle-dc supplied the
rest at runtime through `utilities.sh`. This stack has no such step, so the template's 85-line
version is kept: it reads everything from `/var/run/s6/container_environment/` and sets the
private-files and config-sync paths that match the compose volumes. `overwrite-starter-site.sh`
preserves the existing file across a re-vendor, so this happens by default — but check it after any
re-vendor.

## Verified on this stack

A clean `make clean && make lite-init && make up` on the Drupal 10 pairing produces:

- Drupal 10.6.10 on PHP 8.3.29, `search_api_solr` 4.3.10 against Solr 9.10.1
- all 16 containers healthy, `make ping` exits 0
- `admin` holding `authenticated`, `administrator` and `fedoraadmin`
- `islandora_tags` imported 24/24, plus the two migrations under the `islandora` tag
- `media_thumbnails_video.settings` with `ffmpeg` and `ffprobe` set
- both Lite Solr indexes up to date, the live core stamped `drupal-4.3.10-solr-9.x-0`
- imagick, imagemagick, ffmpeg and ffprobe still present after `make down && make up`

All of it applied by the container itself, with no manual configuration step.
