#!/bin/sh

# replace pattern in file
function replace_in_file() {
	# escape slashes
	pattern=$(echo "$2" | sed "s/\//\\\\\//g")
	replace=$(echo "$3" | sed "s/\//\\\\\//g")
	sed -i "s/$pattern/$replace/g" "$1"
}

# check if a pass meets the constraints
function check_pass() {
	if [ ${#1} -lt $PASSWORD_LENGTH ] ; then
		return 1
	fi
	check=$(echo "$1" | tr -dc '0-9')
	if [ ${#check} -lt $PASSWORD_DIGITS ] ; then
		return 1
	fi
	check=$(echo "$1" | tr -dc 'a-z')
	if [ ${#check} -lt $PASSWORD_LETTERS ] ; then
		return 1
	fi
	check=$(echo "$1" | tr -dc 'A-Z')
	if [ ${#check} -lt $PASSWORD_LETTERS ] ; then
		return 1
	fi
	check=$(echo "$1" | tr -dc '!"#$%&'\''()*+,-./:;<=>?@[\]^_`{|}~')
	if [ ${#check} -lt $PASSWORD_SPECIALS ] ; then
		return 1
	fi
	return 0
}

# generate a random pass and check constraints
function random_pass() {
	while [ 1 ] ; do
		pass=$(cat /dev/urandom | tr -dc 'a-zA-Z0-9!"#$%&'\''()*+,-./:;<=>?@[\]^_`{|}~' | fold -w $PASSWORD_LENGTH | head -n 1)
		check_pass "$pass"
		if [ $? -eq 0 ] ; then
			break
		fi
	done
	echo "$pass"
}

# default values
ROOT_NAME="${ROOT_NAME:-root}"
ROOT_HOST="${ROOT_HOST:-localhost}"
USER_DATABASE="${USER_DATABASE:-${USER_NAME}_db}"
USER_PRIVILEGES="${USER_PRIVILEGES:-ALTER, CREATE, DELETE, DROP, INDEX, INSERT, REFERENCES, SELECT, UPDATE}"
USE_AUTH_ED25519="${USE_AUTH_ED25519:-yes}"
USE_SIMPLE_PASSWORD_CHECK="${USE_SIMPLE_PASSWORD_CHECK:-yes}"
PASSWORD_LENGTH="${PASSWORD_LENGTH:-12}"
PASSWORD_DIGITS="${PASSWORD_DIGITS:-1}"
PASSWORD_LETTERS="${PASSWORD_LETTERS:-1}"
PASSWORD_SPECIALS="${PASSWORD_SPECIALS:-1}"
AUTO_LETS_ENCRYPT="${AUTO_LETS_ENCRYPT:-no}"
SERVER_NAME="${SERVER_NAME:-your.domain.net}"

# random ROOT_PASSWORD if not set
if [ -z "$ROOT_PASSWORD" ] ; then
	echo "[*] ROOT_PASSWORD is not set, random one will be generated."
	ROOT_PASSWORD=$(random_pass)
	echo "[*] generated $ROOT_NAME password : $ROOT_PASSWORD"
	ROOT_PASSWORD=$(echo $ROOT_PASSWORD | sed s/'\\'/'\\\\'/g | sed s/"'"/"\\\'"/g)
fi

# random user password if needed
if [ ! -z "$USER_NAME" ] && [ -z "$USER_PASSWORD" ] ; then
	echo "[*] USER_NAME is set but USER_PASSWORD isn't, random one will be generated."
	USER_PASSWORD=$(random_pass)
	echo "[*] generated $USER_NAME password : $USER_PASSWORD"
	USER_PASSWORD=$(echo $USER_PASSWORD | sed s/'\\'/'\\\\'/g | sed s/"'"/"\\\'"/g)
fi

# check if there is already some data or no
FIRST_INSTALL="yes"
if [ "$(ls /var/lib/mysql)" ] ; then
	FIRST_INSTALL="no"
fi

# stuff to do only on first install
if [ "$FIRST_INSTALL" = "yes" ] ; then

	# initialize database
	echo "[*] initializing system databases ..."
	mkdir -p /usr/lib/mariadb/plugin/auth_pam_tool_dir/auth_pam_tool
	mysql_install_db --skip-test-db --user=mysql --datadir=/var/lib/mysql > /dev/null

	# edit config depending on variables
	cp /opt/mariadb-server.cnf /etc/my.cnf.d/mariadb-server.cnf
	if [ "$USE_AUTH_ED25519" = "yes" ] ; then
		replace_in_file "/etc/my.cnf.d/mariadb-server.cnf" "#plugin_load_add = auth" "plugin_load_add = auth"
	fi
	if [ "$USE_SIMPLE_PASSWORD_CHECK" = "yes" ] ; then
		replace_in_file "/etc/my.cnf.d/mariadb-server.cnf" "#plugin_load_add = simple" "plugin_load_add = simple"
		replace_in_file "/etc/my.cnf.d/mariadb-server.cnf" "%PASSWORD_DIGITS%" "$PASSWORD_DIGITS"
		replace_in_file "/etc/my.cnf.d/mariadb-server.cnf" "%PASSWORD_LETTERS%" "$PASSWORD_LETTERS"
		replace_in_file "/etc/my.cnf.d/mariadb-server.cnf" "%PASSWORD_LENGTH%" "$PASSWORD_LENGTH"
		replace_in_file "/etc/my.cnf.d/mariadb-server.cnf" "%PASSWORD_SPECIALS%" "$PASSWORD_SPECIALS"
	fi

	# setup Let's Encrypt
	echo "" > /etc/crontabs/root
	if [ "$AUTO_LETS_ENCRYPT" = "yes" ] ; then
		if [ ! -d /opt/letsencrypt ] ; then
			mkdir /opt/letsencrypt
			chown root:mysql /opt/letsencrypt
		fi
		if [ -f /etc/letsencrypt/live/${SERVER_NAME}/fullchain.pem ] ; then
			/opt/certbot-renew.sh
		else
			certbot certonly --standalone -n --preferred-challenges http -d $SERVER_NAME --email contact@$SERVER_NAME --agree-tos
			cp /etc/letsencrypt/live/${SERVER_NAME}/fullchain.pem /opt/letsencrypt/ca.pem
			cp /etc/letsencrypt/live/${SERVER_NAME}/cert.pem /opt/letsencrypt/cert.pem
			openssl rsa -in /etc/letsencrypt/live/${SERVER_NAME}/privkey.pem -out /opt/letsencrypt/key.pem
			chown root:mysql /opt/letsencrypt/*.pem
			chmod 640 /opt/letsencrypt/*.pem
			replace_in_file "/etc/my.cnf.d/mariadb-server.cnf" "#ssl_" "ssl_"
			replace_in_file "/etc/my.cnf.d/mariadb-server.cnf" "#tls_" "tls_"
		fi
	fi

	# run mysqld_safe
	echo "[*] starting mysqld_safe ..."
	mysqld_safe &
	sleep 3

	# run mysql_secure_installation
	echo "[*] executing mysql_secure_installation ..."
	echo -e "\nn\n\n${ROOT_PASSWORD}\n${ROOT_PASSWORD}\n\n\n\n\n" | mysql_secure_installation > /dev/null 2>&1

	# remove default mysql user
	mysql -e "DROP USER 'mysql'@'localhost';"

	# setup normal user
	if [ ! -z "$USER_NAME" ] ; then
		mysql -e "CREATE DATABASE $USER_DATABASE;"
		mysql -e "GRANT $USER_PRIVILEGES ON $USER_DATABASE.* TO '$USER_NAME'@'%' IDENTIFIED VIA ed25519 USING PASSWORD('$USER_PASSWORD');"
	fi

	# setup root user
	mysql -e "GRANT ALL PRIVILEGES ON *.* TO '$ROOT_NAME'@'$ROOT_HOST' IDENTIFIED VIA ed25519 USING PASSWORD('$ROOT_PASSWORD') WITH GRANT OPTION;"
else
	# run mysqld_safe
	echo "[*] starting mysqld_safe ..."
	mysqld_safe &
fi

# print logs until container stop
exec tail -f /var/lib/mysql/$(hostname).err

# we have a signal to close the container, let's gracefully stop it
killall -KILL mysqld_safe
mysqladmin shutdown
