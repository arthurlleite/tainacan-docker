# Tainacan Docker
[![Project Status: Inactive – The project has reached a stable, usable state but is no longer being actively developed; support/maintenance will be provided as time allows.](https://www.repostatus.org/badges/latest/inactive.svg)](https://www.repostatus.org/#inactive)

This repository offers Docker files and scripts to build a development environment for [Tainacan](https://github.com/tainacan/tainacan), with WordPress, the Tainacan plugin and the [Tainacan Interface](https://github.com/tainacan/tainacan-theme) theme.

All the tools needed to build the plugin (PHP 8.3, Node, Composer, Sass, WP-CLI and PHPUnit) live inside the containers, so you only need Docker on your machine.

## Requirements

- [Docker Engine](https://docs.docker.com/engine/install/) with the [Compose plugin](https://docs.docker.com/compose/install/linux/) (the `docker compose` command, v2). On Windows, use WSL 2.
- Your user must be able to run `docker` without `sudo` ([post-install steps](https://docs.docker.com/engine/install/linux-postinstall/)).
- Ports `80`, `443` and `3306` free. Stop any local Apache, Nginx or MySQL/MariaDB before starting.
- About 4 GB of free disk space.

## First time setup

```bash
git clone https://github.com/tainacan/tainacan-docker.git
cd tainacan-docker

./dev.sh --build-image   # downloads the docker images
./dev.sh --start         # starts the containers in background
./dev.sh --setup         # installs WordPress, builds the plugin and the theme and activates them
```

The `--setup` step takes a few minutes the first time, as it clones the plugin and theme repositories and installs their dependencies.

When it finishes, open:

| | |
|---|---|
| Site | http://localhost |
| Admin panel | http://localhost/wp-admin |
| User / password | `admin` / `admin` |
| Database (from your machine) | `127.0.0.1:3306`, user `tainacan`, password `tainacan`, database `tainacan` |

You can change the site language, URL and admin credentials by setting `SITE_LANGUAGE`, `SITE_URL`, `SITE_ADMIN_USER` and `SITE_ADMIN_PASSWORD` before running `--setup`, e.g. `SITE_LANGUAGE=pt_BR ./dev.sh --setup`.

## Daily workflow

```bash
./dev.sh --start         # starts the environment
./dev.sh --watch-build   # rebuilds the plugin every time you change a file (Ctrl+C to stop)
./dev.sh --build         # or build it just once
./dev.sh --run-tests     # runs the PHPUnit tests
./dev.sh --stop          # stops the environment
```

The plugin is not loaded directly from its source code: every build compiles the assets (Vue, Sass) and copies the result to `volumes/www/html/public/wp-content/plugins/tainacan`. So **remember to build after every change**, or keep `--watch-build` running.

To run only some tests, pass PHPUnit arguments after `--run-tests`:

```bash
./dev.sh --run-tests --filter Items
```

## Where the code is

| Folder | Content |
|---|---|
| `volumes/src/tainacan` | Git repository of the Tainacan plugin. **This is where you develop.** |
| `volumes/src/tainacan-theme` | Git repository of the Tainacan Interface theme. |
| `volumes/www/html/public` | WordPress installation (generated, do not edit the plugin here). |
| `volumes/mysql/database_data` | Database files. |

The repositories are cloned from the official ones on the first build. To contribute, add your fork as a remote and work on a branch, as described in the [Tainacan contributing guide](https://github.com/tainacan/tainacan/blob/develop/CONTRIBUTING.md):

```bash
cd volumes/src/tainacan
git remote set-url origin https://github.com/tainacan/tainacan.git   # the build sets an SSH url, use HTTPS if you have no SSH key
git remote add fork https://github.com/<your-user>/tainacan.git
git checkout develop && git pull origin develop
git checkout -b feature/<issue-number>-<short-description>
```

You can also clone the repositories yourself into `volumes/src/` before the first build, and the scripts will use them.

## Other commands

```bash
./dev.sh --help               # lists all the commands
./dev.sh --wp plugin list     # runs any WP-CLI command
./dev.sh --bash               # opens a shell in the build container
./dev.sh --bash-mysql         # opens a shell in the database container
./dev.sh --error-logs         # follows the web server error logs
./dev.sh --build-prod         # builds the plugin in production mode
```

WordPress is installed with `WP_DEBUG_LOG` enabled, so PHP errors are also written to `volumes/www/html/public/wp-content/debug.log`.

### Elasticsearch (optional)

Use `--build-image-elastic` and `--start-elastic` instead of `--build-image` and `--start`. The Elasticsearch server will be available at http://localhost:9200. Linux may ask for your password, as Elasticsearch needs a kernel setting (`vm.max_map_count`) to be raised.

## Troubleshooting

**`Bind for 0.0.0.0:80 failed: port is already allocated`**
Another service is using the port. Find it with `sudo ss -ltnp | grep -E ':(80|443|3306)\s'` and stop it (e.g. `sudo systemctl stop apache2 mysql`).

**`http://localhost` shows "Forbidden"**
WordPress is not installed yet. Run `./dev.sh --setup`.

**The Tainacan admin loads, but lists stay empty or show request errors**
The REST API (`http://localhost/wp-json/`) must answer. It depends on the `volumes/www/html/public/.htaccess` file, created by `--setup`. If it was deleted, run `--setup` again.

**Permission denied on files inside `volumes/`**
Files created by old versions of these scripts may be owned by `root`. Fix them with `sudo chown -R $(id -u):$(id -g) volumes/src volumes/www`.

**`npm warn EBADENGINE Unsupported engine` during the build**
The Node version of the build image is slightly older than the one requested by some dependencies. These warnings can be ignored as long as the build ends with `Build complete!`.

**Starting from scratch**
Stop the environment and remove the generated data (your code in `volumes/src` is kept):

```bash
./dev.sh --stop
sudo rm -rf volumes/mysql/database_data volumes/www/html/public/*
./dev.sh --start && ./dev.sh --setup
```

## Building the images

The images used by the compose files are published on [Docker Hub](https://hub.docker.com/u/tainacan). Their Dockerfiles are in the `dockerfiles` folder, in case you need to change and build them locally.
