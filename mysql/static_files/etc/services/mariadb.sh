#!/bin/sh

export HOME="/root"
export USER="root"

# Remove default .my.cnf file
test /root/.my.cnf && rm /root/.my.cnf* -f

# Erase iRedMail certificates if do not exist
if [ ! -e /etc/pki/tls/certs/iRedMail.crt ]; then
    sed -i 's/ssl-/#ssl-/' /etc/my.cnf
fi

# Create database filesystem if does not exist
if [ ! -d /var/lib/mysql/mysql ]; then
    echo -n "*** Creating basic /var/lib/mysql filesystem.. "
    mysql_install_db  --datadir=/var/lib/mysql --skip-name-resolve --force
    chown mysql:mysql /var/lib/mysql -R
    echo "done."

    # Start temporary MariaDB instance
    mysqld_safe &
    mysqlPid=$!
    while ! mysqladmin ping --silent; do sleep 1; done
    echo "SELECT 1;"  | mysql || exit 1

    ### At this moment MariaDB is running, and is open for everyone.. needs to be hardened
    # Update root password
    if [ ! -z ${MYSQL_ROOT_PASSWORD} ]; then
        echo "*** Configuring MySQL database.. "
        if [ "${MYSQL_ROOT_PASSWORD}" != "$CP" ]; then
            echo "(root password) "
            cat << EOF | mysql
    -- What's done in this file shouldn't be replicated
    -- or products like mysql-fabric won't work
    SET @@SESSION.SQL_LOG_BIN=0;
    DELETE FROM mysql.user WHERE user NOT IN ('mysql.sys', 'mysqlxsys', 'root', 'mysql') OR host NOT IN ('localhost') ;
    SET PASSWORD FOR 'root'@'localhost'=PASSWORD('${MYSQL_ROOT_PASSWORD}') ;
    GRANT ALL ON *.* TO 'root'@'localhost' WITH GRANT OPTION ;

    CREATE USER 'root'@'%' IDENTIFIED BY '${MYSQL_ROOT_PASSWORD}' ;
    GRANT ALL ON *.* TO 'root'@'%' WITH GRANT OPTION ;

    DROP DATABASE IF EXISTS test ;
    FLUSH PRIVILEGES ;
EOF
        fi

        cat << EOF > /root/.my.cnf
            [client]
            host=localhost
            user=root
            password="${MYSQL_ROOT_PASSWORD}"
EOF

    fi

    # Import initial structures
    for i in $(ls /opt/iredmail/dumps/*.sql.gz); do 
        dbname=$(basename $i | sed -s 's/.sql.gz//')
        if [ "${dbname}" == "mysql" ]; then
            continue
        fi
        echo "Importing $i into $dbname"; 
        
        # Create database
        echo "CREATE DATABASE $dbname;" | mysql

        # Import data
        zcat $i | mysql $dbname
    done

    # Create and grant technical accounts
    cat << EOF | mysql
    -- TODO: set grant options properly
    SET @@SESSION.SQL_LOG_BIN=0;
    
    -- vmail
    CREATE USER 'vmail'@'localhost' IDENTIFIED BY '${VMAIL_DB_BIND_PASSWD}' ;
    GRANT ALL ON *.* TO 'vmail'@'localhost' WITH GRANT OPTION ;
    -- vmailadmin
    CREATE USER 'vmailadmin'@'localhost' IDENTIFIED BY '${VMAIL_DB_ADMIN_PASSWD}' ;
    GRANT ALL ON *.* TO 'vmailadmin'@'localhost' WITH GRANT OPTION ;
    -- amavisd
    CREATE USER 'amavisd'@'localhost' IDENTIFIED BY '${AMAVISD_DB_PASSWD}' ;
    GRANT ALL ON *.* TO 'amavisd'@'localhost' WITH GRANT OPTION ;
    -- iredadmin
    CREATE USER 'iredadmin'@'localhost' IDENTIFIED BY '${IREDADMIN_DB_PASSWD}' ;
    GRANT ALL ON *.* TO 'iredadmin'@'localhost' WITH GRANT OPTION ;
    -- roundcube
    CREATE USER 'roundcube'@'localhost' IDENTIFIED BY '${IREDADMIN_DB_PASSWD}' ;
    GRANT ALL ON *.* TO 'roundcube'@'localhost' WITH GRANT OPTION ;
    -- sogo
    CREATE USER 'sogo'@'localhost' IDENTIFIED BY '${SOGO_DB_PASSWD}' ;
    GRANT ALL ON *.* TO 'sogo'@'localhost' WITH GRANT OPTION ;
    -- iredapd
    CREATE USER 'iredapd'@'localhost' IDENTIFIED BY '${IREDAPD_DB_PASSWD}' ;
    GRANT ALL ON *.* TO 'iredapd'@'localhost' WITH GRANT OPTION ;    
    FLUSH PRIVILEGES ;
EOF

fi

exit 0


# Update default email accounts
echo "(postmaster) "
DOMAIN=$(hostname -d)
tmp=$(tempfile)
mysqldump vmail mailbox alias domain domain_admins -r $tmp
sed -i "s/DOMAIN/${DOMAIN}/g" $tmp


# Update default email accounts
if [ ! -z ${POSTMASTER_PASSWORD} ]; then
    echo "(postmaster password) "
    echo "UPDATE mailbox SET password='${POSTMASTER_PASSWORD}' WHERE username='postmaster@${DOMAIN}';" >> $tmp
fi
mysql vmail < $tmp > /dev/null 2>&1
rm $tmp


# Update passwords for service accounts
. /opt/iredmail/.cv
tmp=$(tempfile)
echo "DELETE FROM user WHERE Host='hostname.domain';" >> $tmp
echo "SET PASSWORD FOR 'vmail'@'localhost' = PASSWORD('$VMAIL_DB_BIND_PASSWD');" >> $tmp
echo "SET PASSWORD FOR 'vmailadmin'@'localhost' = PASSWORD('$VMAIL_DB_ADMIN_PASSWD');" >> $tmp
echo "SET PASSWORD FOR 'amavisd'@'localhost' = PASSWORD('$AMAVISD_DB_PASSWD');" >> $tmp
echo "SET PASSWORD FOR 'iredadmin'@'localhost' = PASSWORD('$IREDADMIN_DB_PASSWD');" >> $tmp
echo "SET PASSWORD FOR 'roundcube'@'localhost' = PASSWORD('$RCM_DB_PASSWD');" >> $tmp
echo "SET PASSWORD FOR 'sogo'@'localhost' = PASSWORD('$SOGO_DB_PASSWD');" >> $tmp
#echo "SET PASSWORD FOR 'vmail'@'localhost' = PASSWORD('$SOGO_SIEVE_MASTER_PASSWD');" >> $tmp
echo "SET PASSWORD FOR 'iredapd'@'localhost' = PASSWORD('$IREDAPD_DB_PASSWD');" >> $tmp
echo "FLUSH PRIVILEGES;" >> $tmp
echo "(service accounts) "
mysql mysql < $tmp > /dev/null 2>&1


# Stop temporary MySQL
killall -s TERM mysqld
rm $tmp
echo "done."


echo "*** Starting MySQL database.."
touch /var/tmp/mysql.run
exec /sbin/setuser mysql /usr/sbin/mysqld