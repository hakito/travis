#!/bin/bash

if [ "$PHPCS" = '1' ]; then
	pear channel-discover pear.cakephp.org
	pear install --alldeps cakephp/CakePHP_CodeSniffer
	phpenv rehash
	exit 0
fi

#
# Returns the latest reference (either a branch or tag) for any given
# MAJOR.MINOR semantic versioning.
#
latest_ref() {
	# Get version from master branch
	MASTER=$(curl --silent https://raw.github.com/cakephp/cakephp/master/lib/Cake/VERSION.txt)
	MASTER=$(echo "$MASTER" | tail -1 | grep -Ei "^$CAKE_VERSION\.")
	if [ -n "$MASTER" ]; then
		echo "master"
		exit 0
	fi

	# Check if any branch matches CAKE_VERSION
	BRANCH=$(curl --silent https://api.github.com/repos/cakephp/cakephp/git/refs/heads)
	BRANCH=$(echo "$BRANCH" | grep -Ei "\"refs/heads/$CAKE_VERSION\"" | grep -oEi "$CAKE_VERSION" | tail -1)
	if [ -n "$BRANCH" ]; then
		echo "$BRANCH"
		exit 0
	fi

	# Get the latest tag matching CAKE_VERSION.*
	TAG=$(curl --silent https://api.github.com/repos/cakephp/cakephp/git/refs/tags)
	TAG=$(echo "$TAG" | grep -Ei "\"refs/tags/$CAKE_VERSION\." | grep -oEi "$CAKE_VERSION\.[^\"]+" | tail -1)
	if [ -n "$TAG" ]; then
		echo "$TAG"
		exit 0
	fi
}

vercomp () {
    if [[ $1 == $2 ]]
    then
        return 0
    fi
    local IFS=.
    local i ver1=($1) ver2=($2)
    # fill empty fields in ver1 with zeros
    for ((i=${#ver1[@]}; i<${#ver2[@]}; i++))
    do
        ver1[i]=0
    done
    for ((i=0; i<${#ver1[@]}; i++))
    do
        if [[ -z ${ver2[i]} ]]
        then
            # fill empty fields in ver2 with zeros
            ver2[i]=0
        fi
        if ((10#${ver1[i]} > 10#${ver2[i]}))
        then
            return 1
        fi
        if ((10#${ver1[i]} < 10#${ver2[i]}))
        then
            return 2
        fi
    done
    return 0
}

if [ "$DB" = "mysql" ]; then mysql -e 'CREATE DATABASE cakephp_test;'; fi
if [ "$DB" = "pgsql" ]; then psql -c 'CREATE DATABASE cakephp_test;' -U postgres; fi

REPO_PATH=$(pwd)
SELF_PATH=$(cd "$(dirname "$0")"; pwd)

# Clone CakePHP repository
CAKE_REF=$(latest_ref)
if [ -z "$CAKE_REF" ]; then
	echo "Found no valid ref to match with version $CAKE_VERSION" >&2
	exit 1
fi

git clone git://github.com/cakephp/cakephp.git --branch $CAKE_REF --depth 1 ../cakephp

# Prepare plugin
cd ../cakephp/app

chmod -R 777 tmp

cp -R $REPO_PATH Plugin/$PLUGIN_NAME

mv $SELF_PATH/database.php Config/database.php

COMPOSER_JSON="$(pwd)/Plugin/$PLUGIN_NAME/composer.json"
if [ -f "$COMPOSER_JSON" ]; then
    cp $COMPOSER_JSON ./composer.json;
    composer install --no-interaction --prefer-source
fi

for dep in $REQUIRE; do
    composer require --no-interaction --prefer-source $dep;
done

if [ "$COVERALLS" = '1' ]; then
	composer require php-coveralls/php-coveralls=2.1.0
fi

if [ "$PHPCS" != '1' ]; then
    PHP_VERSION=$(php -v | head -n 1 | cut -d ' ' -f2)
	PHP_UNIT_VERSION=3.7.38
	vercomp $PHP_VERSION 6.9
	case $? in
       # 0) PHP_UNIT_VERSION;;
        1) PHP_UNIT_VERSION='8.*'
	   cat <<EOT >> ../cakephp/app/Config/bootstrap.php
// Load Composer autoload.
require APP . 'Vendor/autoload.php';

// Remove and re-prepend CakePHP's autoloader as Composer thinks it is the
// most important.
// See: http://goo.gl/kKVJO7
spl_autoload_unregister(array('App', 'load'));
spl_autoload_register(array('App', 'load'), true, true);
EOT
	;;
        #2) op='<';;
    esac

	composer global require "phpunit/phpunit=$PHP_UNIT_VERSION"
	ln -s ~/.config/composer/vendor/phpunit/phpunit/PHPUnit ./Vendor/PHPUnit
fi

phpenv rehash

set +H

echo "CakePlugin::loadAll(array(array('bootstrap' => true, 'routes' => true, 'ignoreMissing' => true)));" >> Config/bootstrap.php

echo "<?xml version=\"1.0\" encoding=\"UTF-8\"?>
<phpunit bootstrap=\"vendor/autoload.php\">
<filter>
    <whitelist>
        <directory suffix=\".php\">Plugin/$PLUGIN_NAME</directory>
        <exclude>
            <directory suffix=\".php\">Plugin/$PLUGIN_NAME/Test</directory>
        </exclude>
    </whitelist>
</filter>
<logging>
  <log type=\"junit\" target=\"tmp/logfile.xml\" logIncompleteSkipped=\"false\"/>
</logging>
</phpunit>" > phpunit.xml

echo "# for php-coveralls
src_dir: Plugin/$PLUGIN_NAME
coverage_clover: build/logs/clover.xml
json_path: build/logs/coveralls-upload.json" > .coveralls.yml
