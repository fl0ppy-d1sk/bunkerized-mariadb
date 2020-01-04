# bunkerized-mariadb
mariadb based Docker image secure by default.

## Main features
- Configure strong password policy
- Set privileges for user
- TLS support with transparent Let's Encrypt automation
- Based on alpine (< X MB image)
- Easy to configure with environment variables

## Quickstart guide

### Run MariaDB server with default settings

```shell
docker run -p 3306:3306 -v /where/to/save/databases:/var/lib/mysql bunkerity/bunkerized-mariadb
```

TODO : TLS

## List of environment variables

TODO
