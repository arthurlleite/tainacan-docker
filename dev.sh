#!/bin/bash

# Always run from the repository root, so the compose files and volumes are found
cd "$(dirname "$0")"

COMPOSE="docker compose -f docker-compose.yml -f docker-compose.dev.yml"
COMPOSE_ELASTIC="$COMPOSE -f docker-compose.dev.elastic.yml"

# The web server runs with the host user ids, so it can write on the mounted volumes
export PUID=${PUID:-$(id -u)}
export PGID=${PGID:-$(id -g)}

# Only ask docker for a TTY when there is one (allows running the script from CI or other scripts)
if [ -t 0 ] && [ -t 1 ]; then TTY="-it"; else TTY="-i"; fi

# Commands that generate files on the volumes run with the host user, so they are not owned by root
BUILD_EXEC="docker exec $TTY -u $PUID:$PGID -e HOME=/tmp tainacan_build"
BUILD_EXEC_ROOT="docker exec $TTY tainacan_build"

WP_PATH="/var/www/html/public"
SITE_URL=${SITE_URL:-http://localhost}
SITE_LANGUAGE=${SITE_LANGUAGE:-en_US}
SITE_ADMIN_USER=${SITE_ADMIN_USER:-admin}
SITE_ADMIN_PASSWORD=${SITE_ADMIN_PASSWORD:-admin}

function fn_prepare_volumes {
    # If docker creates these folders on its own, they end up owned by root
    mkdir -p volumes/src volumes/www/html/public volumes/mysql/database_data
}

function fn_wait_db {
    if [ "$(docker inspect -f '{{.State.Running}}' tainacan_db 2> /dev/null)" != "true" ]; then
        echo "The database container is not running. Start the environment with: ./dev.sh --start"
        exit 1
    fi

    echo "Waiting for the database..."
    local tries=0
    until docker exec tainacan_db mariadb-admin ping -uroot -ptainacan --silent > /dev/null 2>&1; do
        tries=$((tries + 1))
        if [ $tries -ge 30 ]; then
            echo "The database did not answer after 60 seconds. Check its logs with: docker logs tainacan_db"
            exit 1
        fi
        sleep 2
    done
}

function fn_stop {
    echo "[STOP TAINACAN]"
    $COMPOSE_ELASTIC down
}

function fn_start {
    echo "[START TAINACAN]"
    fn_prepare_volumes
    $COMPOSE up -d || exit 1
    echo "Tainacan is running at $SITE_URL"
}

function fn_start_elastic {
    echo "[START TAINACAN WITH ELASTIC]"
    fn_prepare_volumes
    sudo sysctl -w vm.max_map_count=262144
    $COMPOSE_ELASTIC up -d || exit 1
    echo "Tainacan is running at $SITE_URL"
}

function fn_build {
    $BUILD_EXEC sh -c "/src_base/scripts/build_plugin.sh $1" || exit 1
    $BUILD_EXEC sh -c "/src_base/scripts/build_theme.sh" || exit 1
}

function fn_setup {
    echo "[SETUP WORDPRESS]"
    fn_wait_db

    $BUILD_EXEC bash -c "
        cd $WP_PATH
        if wp core is-installed > /dev/null 2>&1; then
            echo 'WordPress is already installed.'
        else
            wp core download --locale=$SITE_LANGUAGE &&
            wp config create --dbname=tainacan --dbuser=tainacan --dbpass=tainacan --dbhost=tainacan_db:3306 --locale=$SITE_LANGUAGE --extra-php <<< \"define( 'WP_DEBUG', true ); define( 'WP_DEBUG_LOG', true ); define( 'WP_DEBUG_DISPLAY', false );\" &&
            wp core install --url=$SITE_URL --title=Tainacan --admin_user=$SITE_ADMIN_USER --admin_password=$SITE_ADMIN_PASSWORD --admin_email=admin@example.com --skip-email || exit 1
        fi
        wp rewrite structure '/%postname%/'
    " || exit 1

    # wp-cli can not write the .htaccess by itself and, without it, the REST API used by Tainacan returns 404
    if [ ! -f volumes/www/html/public/.htaccess ]; then
        cat > volumes/www/html/public/.htaccess << 'EOF'
# BEGIN WordPress
<IfModule mod_rewrite.c>
RewriteEngine On
RewriteRule .* - [E=HTTP_AUTHORIZATION:%{HTTP:Authorization}]
RewriteBase /
RewriteRule ^index\.php$ - [L]
RewriteCond %{REQUEST_FILENAME} !-f
RewriteCond %{REQUEST_FILENAME} !-d
RewriteRule . /index.php [L]
</IfModule>
# END WordPress
EOF
    fi

    echo "[BUILD TAINACAN]"
    fn_build --build

    $BUILD_EXEC bash -c "cd $WP_PATH && wp plugin activate tainacan && wp theme activate tainacan-interface" || exit 1

    echo "
    Done! Access $SITE_URL/wp-admin with user '$SITE_ADMIN_USER' and password '$SITE_ADMIN_PASSWORD'.
    "
}

function fn_run_tests {
    echo "[RUNNING TESTS - PHPUnit]"
    fn_wait_db

    # The 'tainacan' database user is not allowed to create databases, so the test database is created by root
    docker exec tainacan_db mariadb -uroot -ptainacan -e "CREATE DATABASE IF NOT EXISTS tainacan_test; GRANT ALL PRIVILEGES ON tainacan_test.* TO 'tainacan'@'%';" || exit 1

    $BUILD_EXEC bash -c "
        cd /src/tainacan &&
        if [ ! -f tests/bootstrap-config.php ]; then
            sed 's#/tmp/wordpress/wordpress-tests-lib#'\$WP_TESTS_DIR'#' tests/bootstrap-config-sample.php > tests/bootstrap-config.php
        fi
    " || exit 1

    # To avoid leaving root-owned files on mounted volumes, the test folder is created as root then ownership is changed to the host user 
    # Files under /tmp are also changed to the host user, in case there are temporary files
    $BUILD_EXEC_ROOT bash -c "
        mkdir -p \$WORDPRESS_PATH_TEST &&
        chown -R $PUID:$PGID \$WORDPRESS_PATH_TEST &&
        find /tmp -mindepth 1 -maxdepth 1 -user root -exec chown -R $PUID:$PGID {} +
    " || exit 1

    $BUILD_EXEC bash -c "
        cd /src/tainacan &&
        if [ ! -d \$WP_TESTS_DIR ]; then
            ./tests/bin/install-wp-tests.sh \$WORDPRESS_DB_TEST \$WORDPRESS_DB_USER \$WORDPRESS_DB_PASSWORD \$WORDPRESS_PATH_TEST \$WORDPRESS_DB_HOST latest true || exit 1
        fi
        phpunit ${*}
    "
}

function fn_generate_docs {
    echo "[GENERATE DOCS]"
    local source=$1
    local output=$2
    sudo docker run --rm -v "$source:/data" -it --entrypoint /bin/bash "phpdoc/phpdoc:3"
}

case $1 in
    --build-image)
        echo "[BUILD IMAGE]"
        # The images are published on Docker Hub, so this downloads them
        $COMPOSE pull
        exit
    ;;
    --build-image-elastic)
        echo "[BUILD IMAGE WITH ELASTICSEARCH]"
        $COMPOSE_ELASTIC pull
        exit
    ;;
    --setup)
        fn_setup
        exit
    ;;
    --build)
        echo "[BUILD TAINACAN]"
        fn_build --build
        exit
    ;;
    --build-prod)
        echo "[BUILD TAINACAN]"
        fn_build --build-prod
        exit
    ;;
    --watch-build)
        echo "[BUILD WATCH TAINACAN]"
        $BUILD_EXEC sh -c "/src_base/scripts/build_theme.sh"
        $BUILD_EXEC sh -c "/src_base/scripts/build_plugin.sh --watch-build"
        exit
    ;;
    --stop)
        fn_stop
        exit
    ;;
    --start)
        fn_start
        exit
    ;;
    --start-elastic)
        echo "[START TAINACAN WITH ELASTICSEARCH]"
        fn_start_elastic
        exit
    ;;
    --run-tests)
        shift
        fn_run_tests "$@"
        exit
    ;;
    --wp)
        shift
        $BUILD_EXEC wp --path=$WP_PATH "$@"
        exit
    ;;
    --bash)
        echo "[INTO A CONTAINER /bin/bash]"
        $BUILD_EXEC /bin/bash
        exit
    ;;
    --bash-mysql)
        echo "[INTO A CONTAINER OF MYSQL /bin/bash]"
        docker exec $TTY tainacan_db /bin/bash
        exit
    ;;
    --error-logs)
        echo "[ERRORS LOG tainacan-dev]"
        docker logs -f tainacan_fpm_apache > /dev/null
        exit
    ;;
    --generate-docs)
        fn_generate_docs "$2"
        exit
    ;;
    --help)
        echo "
        --build-image         =  downloads the docker images for application and database.
        --build-image-elastic =  downloads the docker images for application, database and elasticsearch server.
        --start               =  starts the containers in background.
        --start-elastic       =  starts the containers and the elasticsearch server in background (asks for sudo).
        --setup               =  installs WordPress, builds the plugin and theme and activates them (run once, after --start).
        --stop                =  stops all containers.
        --build               =  builds tainacan plugin and theme.
        --build-prod          =  builds tainacan plugin and theme in production mode.
        --watch-build         =  watches for changes in the plugin and builds it.
        --run-tests [args]    =  runs phpunit tests. Extra args are passed to phpunit, e.g. --run-tests --filter Items
        --wp [command]        =  runs a wp-cli command, e.g. --wp plugin list
        --bash                =  enters the build container.
        --bash-mysql          =  enters the database container.
        --error-logs          =  displays the web server error logs.
        --help                =  displays this help message.
        "
        exit
    ;;
esac
echo "Invalid option, for help: --help"
exit 1
