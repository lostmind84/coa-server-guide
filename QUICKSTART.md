# CoA server with Docker: command sequence

Commands only. Explanations, checks and pitfalls: [README.md](README.md). Automated version of steps 4–8:
[`scripts/setup-coa-server.sh`](scripts/setup-coa-server.sh).

Assumes: Linux, Docker with Compose and buildx, uid 1000, the client/patch/repack archives extracted under
`~/CoaServer/{client,repack}`.

## 1. Code and images

```bash
git clone https://github.com/jealous-sound/azerothcore-wotlk-coa.git ~/Projects/azerothcore-wotlk-coa
cd ~/Projects/azerothcore-wotlk-coa
# Until PR #243 is merged: add the Boost fix
grep -q "boost/bind/placeholders.hpp" modules/mod-ascension-compat/src/CoAGameplayTest.cpp || \
  sed -i 's|#include <boost/property_tree/json_parser.hpp>|#include <boost/bind/placeholders.hpp>\n&|' \
  modules/mod-ascension-compat/src/CoAGameplayTest.cpp
docker compose build
```

## 2. Client patch

```bash
cd ~/CoaServer/client
mkdir -p ~/CoaServer/backups/client-before-rev3
cp -a ascension-live/Ascension.exe ascension-live/Data/patch-B.MPQ ascension-live/Data/patch-T.MPQ ~/CoaServer/backups/client-before-rev3/
cp -a CoA-Client-Patch/Ascension.exe CoA-Client-Patch/Extensions.dll ascension-live/
cp -a CoA-Client-Patch/Data/. ascension-live/Data/
sha256sum ascension-live/Ascension.exe ascension-live/Extensions.dll ascension-live/Data/patch-B.MPQ ascension-live/Data/patch-T.MPQ
# f4b9f6fc… 97918010… e16fd42b… ad183192…
```

## 3. Server layout and data

```bash
sudo mkdir -p /srv/coa && sudo chown "$(id -u):$(id -g)" /srv/coa
mkdir -p /srv/coa/{etc/modules,logs,backups,server-data}
cp -a ~/CoaServer/repack/CoA-Repack/Data/. /srv/coa/server-data/
echo "INSTALLED_VERSION=v20.0" > /srv/coa/server-data/data-version
```

## 4. Configuration

```bash
cd ~/Projects/azerothcore-wotlk-coa
cat > .env <<EOF
DOCKER_DB_ROOT_PASSWORD=$(openssl rand -hex 16)
DOCKER_DB_EXTERNAL_PORT=127.0.0.1:3306
DOCKER_AUTH_EXTERNAL_PORT=127.0.0.1:3724
DOCKER_WORLD_EXTERNAL_PORT=127.0.0.1:8085
DOCKER_SOAP_EXTERNAL_PORT=127.0.0.1:7878
DOCKER_VOL_ETC=/srv/coa/etc
DOCKER_VOL_LOGS=/srv/coa/logs
DOCKER_VOL_DATA=/srv/coa/server-data
DOCKER_AC_ENV_FILE=/srv/coa/coa.env
EOF
chmod 600 .env

cp conf/dist/env.ac /srv/coa/coa.env
cat >> /srv/coa/coa.env <<'EOF'

# CoA settings from the repack (Settings/*.template)
AC_ASCENSION_COMPAT_ALLOW_REMOTE_CLIENTS=1
AC_ASCENSION_COMPAT_DBC_DIRECTORY=/azerothcore/env/dist/data/dbc/Ascension
AC_ASCENSION_MANASTORM_ENABLE=1
AC_PLAYER_START_CUSTOM_SPELLS=1
EOF

for f in modules/*/conf/*.conf.dist; do cp -n "$f" "/srv/coa/etc/modules/$(basename "${f%.dist}")"; done

docker compose config | grep -E "host_ip|source: /srv|AC_ASCENSION|AC_PLAYER_START"
```

## 5. Database

```bash
docker compose up -d ac-database
docker compose ps   # wait for "healthy"

zcat ~/CoaServer/repack/CoA-Repack/Database/Clean/databases.sql.gz \
  | docker compose exec -T ac-database sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'

docker compose exec -T ac-database sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' <<'SQL'
UPDATE acore_auth.realmlist SET port = 8085 WHERE id = 1;
UPDATE acore_world.updates SET hash = '9AB2C61CBDE30910A9044DE96CC7EF4C64C6D391'
  WHERE name = 'rev_1787754600000000000.sql' AND hash = '563E4DD451533A7E56EF69D7536127BE836026BD';
UPDATE acore_world.updates SET hash = '91203FA3DBE929E388DA88BD0822BFA140355C4B'
  WHERE name = '2026_08_26_01_ascension_appearance_item_templates.sql' AND hash = 'EC1B200FDA9C234431A90717D347F6A42444676F';
SQL

docker compose up ac-db-import 2>&1 | tee /srv/coa/logs/db-import-$(date +%F).log
docker compose ps -a ac-db-import   # Exited (0), no "Reapplying update" in the log
```

## 6. Start

```bash
docker compose up -d ac-authserver ac-worldserver
docker compose logs -f ac-worldserver   # wait for "(worldserver-daemon) ready...", Ctrl+C stops following only
```

## 7. GM account password

```bash
docker compose attach ac-worldserver
# account set password local NEW_PASSWORD NEW_PASSWORD
# detach: Ctrl+P then Ctrl+Q
```

## 8. Client

```bash
cd ~/CoaServer/client/ascension-live
WINEPREFIX="$HOME/Games/umu/coa-client" GAMEID=0 \
PROTONPATH="$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton11-6-x86_64" \
WINEDLLOVERRIDES="divxtac=d" \
umu-run Ascension.exe
```

`divxtac=d` is required: without it the client freezes on the loading screen at 100%. Or use the launcher:

```bash
cp ~/Projects/coa-server-guide/scripts/coa-client ~/.local/bin/ && chmod +x ~/.local/bin/coa-client
coa-client            # --debug for a Proton log, --kill to stop a frozen client
```

## Daily use

```bash
cd ~/Projects/azerothcore-wotlk-coa
docker compose up -d ac-authserver ac-worldserver   # start (MySQL starts too)
docker compose stop                                 # stop everything
docker compose logs -f ac-worldserver               # follow logs
```

Never run `docker compose pull`.
