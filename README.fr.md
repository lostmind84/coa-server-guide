# Serveur Conquest of Azeroth (CoA) sous Linux avec Docker

Guide pas à pas pour faire tourner le serveur **Conquest of AzerothCore** sur un PC Linux sans installer ses
dépendances de compilation sur le système, organisé pour pouvoir passer ensuite sur un VPS avec peu de changements.

- Version anglaise (référence) : [README.md](README.md)
- Commandes seules (en anglais) : [QUICKSTART.md](QUICKSTART.md)
- Étapes 8 à 11 automatisées : [`scripts/setup-coa-server.sh`](scripts/setup-coa-server.sh)

État au 2026-09-15 : étapes 1 à 13 réalisées et vérifiées sur la machine de test : serveur démarré, données
Ascension chargées, mot de passe GM changé, client connecté, personnage de classe custom créé et **entré dans le
monde**. Le script d'installation a été vérifié syntaxiquement et sa conversion d'empreintes testée en lecture seule
sur la base en service ; il n'a pas encore été exécuté de bout en bout sur une machine vierge. Le gameplay au-delà de
l'entrée dans le monde n'a pas été testé.

| Élément | Version utilisée |
| --- | --- |
| Dépôt serveur | [`jealous-sound/azerothcore-wotlk-coa`](https://github.com/jealous-sound/azerothcore-wotlk-coa) `main` au commit `bb1d48a5f` (PR #235) + correctif de build Boost ([PR #243](https://github.com/jealous-sound/azerothcore-wotlk-coa/pull/243)) |
| Repack | `ability-fixes-20260914` (sources `126ee7d`, après les PR #130/#133) |
| Patch client | `ability-fixes-20260914`, révision client 3 |
| Machine de test | Arch Linux, Docker + Compose + buildx, 16 cœurs, 125 Go RAM, uid 1000 |

---

## 1. Comprendre les pièces

- **Client** : le jeu installé par le joueur (~44 Go). World of Warcraft 3.3.5a modifié par Ascension. Programme
  Windows : sous Linux il faut Wine/Proton. Il affiche le jeu, il ne décide rien.
- **Serveur** : deux programmes et une base MySQL.
  - `authserver` (port 3724) : vérifie le compte, envoie la liste des royaumes.
  - `worldserver` (port 8085) : fait tourner le monde (sorts, IA, quêtes…).
  - MySQL 8.4 avec trois bases : `acore_auth` (comptes, royaumes), `acore_world` (contenu du jeu),
    `acore_characters` (personnages).
- **Données serveur** (`dbc`, `maps`, `vmaps`, `mmaps`, `Cameras`) : fichiers extraits du client pour que le
  serveur connaisse sorts, terrain, lignes de vue et chemins. Depuis jealous-sound/azerothcore-wotlk-coa#1498,
  `dbc/` doit contenir le jeu de DBC du client CoA lui-même, extrait du client d'origine (étape 8).
- **Client Patch** : fichiers à copier par-dessus le client (`Ascension.exe`, `Extensions.dll`, `patch-B.MPQ`,
  `patch-T.MPQ`, `realmlist.wtf`) pour l'adapter au serveur CoA.
- **Repack** : serveur **déjà compilé et prêt à lancer pour Windows** (exécutables, MySQL portable, bases remplies,
  données serveur, configs, scripts `.bat`). Ce guide ne lance aucun de ses exécutables : il réutilise ses **données
  serveur** et son **dump de base de données**.

Connexion d'un joueur : client → `realmlist.wtf` → authserver (3724) → adresse du royaume lue dans
`acore_auth.realmlist` → worldserver (8085).

Démarrage du worldserver (`src/server/apps/worldserver/Main.cpp`) : lecture des configs (dont celles des modules) →
connexion aux bases (et mises à jour SQL si activées) → chargement du monde (DBC, sorts, templates, scripts, maps)
→ ouverture du port 8085 → boucle de mise à jour du monde.

## 2. Choisir comment faire tourner le serveur

| Option | Verdict |
| --- | --- |
| Natif sur Arch | Déconseillé : MySQL 8.4 non packagé (MariaDB **non supportée**, erreur ACE00043), en-têtes Boost à installer, distribution non supportée officiellement (Ubuntu 24.04/26.04, Debian 12/13 le sont). |
| VM Ubuntu | Possible, isolation totale, mais ressources réservées et le client se connecte à une IP distante. |
| **Docker** | **Retenu** : toutes les dépendances restent dans des images Ubuntu 24.04. Le dépôt fournit déjà `docker-compose.yml`. |

Pourquoi ne pas compiler sur l'hôte puis copier les binaires dans Docker : aucun gain (Docker n'est pas une VM sous
Linux) et binaires probablement incompatibles (glibc 2.44 sur Arch contre 2.39 dans Ubuntu 24.04, versions de
Boost/OpenSSL/libmysqlclient différentes). Pour les recompilations fréquentes, utiliser le service `ac-dev-server`
(profil `dev`), qui garde le dossier de build et ccache dans des volumes.

Le repack officiel n'utilise pas Docker : il vise des joueurs sous Windows (double-clic sur `Start_All_Server.bat`).
Le `docker-compose.yml` du dépôt vient d'AzerothCore standard et ne contient rien de spécifique à CoA ; ce guide
ajoute les étapes CoA.

## 3. Ce que Docker construit

`apps/docker/Dockerfile` compile tout une seule fois (étape `build` : Ubuntu 24.04, clang, Ninja, ccache,
`-DAPPS_BUILD=all -DTOOLS_BUILD=all -DSCRIPTS=static -DMODULES=static`) puis copie chaque binaire dans son image :

| Image | Contenu |
| --- | --- |
| `acore/ac-wotlk-worldserver:master` | `worldserver` (cœur + scripts + module `mod-ascension-compat`) |
| `acore/ac-wotlk-authserver:master` | `authserver` |
| `acore/ac-wotlk-db-import:master` | `dbimport` + `data/` + SQL des modules |
| `acore/ac-wotlk-client-data:master` | script qui télécharge les données **standard** v20.0 |
| `mysql:8.4` | image officielle, non compilée |

Dépendances système dans l'image de build : Boost 1.83, OpenSSL, client MySQL, readline, zlib, bzip2. Fournies dans
`deps/` : argon2, g3dlite, jemalloc, libmpq, recastnavigation, fmt, etc.

## 4. Arborescence

Les fichiers côté serveur vont dans `/srv/coa` (emplacement conventionnel des données servies par une machine) pour
que les mêmes chemins fonctionnent sur un VPS. Ce qui ne concerne que le poste de travail reste dans le dossier
personnel.

```
~/Projects/azerothcore-wotlk-coa/   dépôt git (code) + .env (réglages Docker Compose, ignoré par git)
/srv/coa/                           côté serveur : identique sur le PC et sur un VPS
├── coa.env                         réglages serveur transmis aux conteneurs (variables AC_*)
├── server-data/                    dbc, maps, vmaps, mmaps (3,3 Go)
├── etc/                            configs serveur (créées par les conteneurs) + etc/modules/*.conf
├── logs/                           logs serveur, import et build
└── backups/                        sauvegardes MySQL
~/CoaServer/                        poste de travail uniquement, jamais sur un serveur
├── client/                         ascension-live/ (client) + CoA-Client-Patch/
├── repack/                         CoA-Repack/ : référence, jamais lancé
├── downloads/
└── backups/                        fichiers client remplacés
```

Les données MySQL sont dans le volume Docker `azerothcore-wotlk-coa_ac-database`, pas dans `/srv/coa`.

```bash
sudo mkdir -p /srv/coa && sudo chown "$(id -u):$(id -g)" /srv/coa
mkdir -p /srv/coa/{etc/modules,logs,backups,server-data}
mkdir -p ~/CoaServer/{downloads,client,repack,backups}
```

Le propriétaire doit être l'uid 1000 : les images sont construites avec `DOCKER_USER_ID=1000` et les conteneurs
écrivent dans `etc/` et `logs/`.

## 5. Construire les images

```bash
git clone https://github.com/jealous-sound/azerothcore-wotlk-coa.git ~/Projects/azerothcore-wotlk-coa
cd ~/Projects/azerothcore-wotlk-coa
docker compose config --services         # doit lister 5 services
docker compose build 2>&1 | tee /srv/coa/logs/build-$(date +%F).log
docker images | grep acore
docker run --rm --entrypoint /azerothcore/env/dist/bin/worldserver acore/ac-wotlk-worldserver:master --version
```

- `./acore.sh docker build` fait exactement `docker compose build`.
- Premier build observé : 1 340 cibles en ~392 s, 0 erreur, 55 avertissements. Un rebuild après la modification d'un
  fichier a pris ~23 s de compilation grâce à ccache.
- Sur `main` au commit `bb1d48a5f`, le build échoue tant que la PR #243 n'est pas intégrée (voir
  [Pièges connus](#pièges-connus)). Appliquer d'abord le correctif d'une ligne :

```bash
grep -q "boost/bind/placeholders.hpp" modules/mod-ascension-compat/src/CoAGameplayTest.cpp || \
  sed -i 's|#include <boost/property_tree/json_parser.hpp>|#include <boost/bind/placeholders.hpp>\n&|' \
  modules/mod-ascension-compat/src/CoAGameplayTest.cpp
```

## 6. Télécharger et vérifier client, patch et repack

L'auteur du fork partage le client, le patch client et le repack sur le canal Discord du projet. Les décompresser
dans `~/CoaServer/client/` et `~/CoaServer/repack/`.

**Ne lancer aucun `.bat` ni `.exe`.** Vérifications faites :

- Les 9 `.bat` du repack ne font qu'appeler `Runtime/python/python.exe Scripts/manage.py <action>`.
- `CoA-Client-Patch/CLIENT-RELEASE.json` donne le SHA256 de chaque fichier ; ils correspondent, et ceux de l'EXE et
  de la DLL correspondent aussi à `apps/client-compat/README.md` du dépôt :

| Fichier | SHA256 |
| --- | --- |
| `Ascension.exe` (manifeste passé en `asInvoker`) | `f4b9f6fce448194638c5b1c751483090a48c597c6272237f31b3d151b50d3114` |
| `Extensions.dll` (correctif d'adresse monde) | `9791801053f828d1ccdab1a4c17e64852d3ebe0fa708b91fa3674d0805d15bc8` |
| `Data/patch-B.MPQ` | `e16fd42b8a98368de9962d5c3ac07996c14f1c39798ce1fe61e90ad246c92ede` |
| `Data/patch-T.MPQ` | `ad183192246cb453673eba7be58649cbd33c00da6556b2f4906d5b357705d626` (plus installé depuis #1498, étape 7) |

- `Database/Clean/snapshot.json` contient l'empreinte du dump (`gzipSHA256`) ; le script d'installation la vérifie.
- `BugReport/relay.py` envoie les rapports de bugs du jeu à un service externe qui crée des issues GitHub publiques
  sur le fork ; il embarque une clé d'API de distribution. Il n'est pas utilisé ici (`CoABugReport.Enable = 0`).
- Wine n'est **pas** un bac à sable : un programme lancé sous Wine accède au `$HOME` via `Z:`. Utiliser un préfixe
  dédié.

Contenu utile du repack :

| Chemin | Usage |
| --- | --- |
| `Data/` (3,3 Go) | données serveur complètes, dont `dbc/Ascension/` |
| `Database/Clean/databases.sql.gz` | dump MySQL 8.4.9 des 3 bases (22/117/321 tables) ; compte `local`/`local` GM 3, aucun personnage ; migrations world jusqu'à `rev_20260914_15` |
| `Settings/*.template` | réglages de référence (repris à l'étape 9) |
| `RELEASE.json`, `RELEASE.txt` | version, empreintes des binaires, changements |

## 7. Appliquer le patch client

```bash
cd ~/CoaServer/client
mkdir -p ~/CoaServer/backups/client-before-rev3
cp -a ascension-live/Ascension.exe ascension-live/Data/patch-B.MPQ ascension-live/Data/patch-T.MPQ \
      ~/CoaServer/backups/client-before-rev3/
cp -a CoA-Client-Patch/Ascension.exe CoA-Client-Patch/Extensions.dll ascension-live/
cp -a CoA-Client-Patch/Data/. ascension-live/Data/
sha256sum ascension-live/Ascension.exe ascension-live/Extensions.dll \
          ascension-live/Data/patch-B.MPQ ascension-live/Data/patch-T.MPQ
```

Les empreintes doivent correspondre au tableau de l'étape 6. `Data/enUS/realmlist.wtf` contient déjà
`set realmlist 127.0.0.1`.

Depuis #1498, serveur et joueurs utilisent le jeu de DBC du client d'origine, et les joueurs ne doivent pas recevoir
le `patch-T.MPQ` du patch (sa seule archive contenant des DBC). Le launcher garde la copie intacte sous
`patch-T.MPQ.ORIGINAL` :

```bash
cd ~/CoaServer/client/ascension-live/Data
mkdir -p ~/CoaServer/backups/client-rev4 && mv patch-T.MPQ ~/CoaServer/backups/client-rev4/
cp patch-T.MPQ.ORIGINAL patch-T.MPQ
```

## 8. Données serveur

```bash
cp -a ~/CoaServer/repack/CoA-Repack/Data/. /srv/coa/server-data/
echo "INSTALLED_VERSION=v20.0" > /srv/coa/server-data/data-version
```

Le `dbc/` du repack n'est pas le jeu client que le worldserver exige désormais (il s'arrête sur `DataDir does not
hold the CoA client DBC set`). Extraire ce jeu du client d'origine avec l'outil du dépôt puis le copier. Il faut
[mpqcli](https://github.com/TheGrayDot/mpqcli) (binaire Linux de la release, par exemple dans `~/.local/bin`) :

```bash
cd ~/Projects/azerothcore-wotlk-coa
out=~/CoaServer/client-dbc/original-$(date +%F)
python3 apps/coa-dbc/client_dbc.py extract ~/CoaServer/client/ascension-live/Data "$out" --original \
  --mpqcli "$(command -v mpqcli)"                       # finit par "110 core tables checked, 0 problems"
cp -a --reflink=auto /srv/coa/server-data/dbc /srv/coa/backups/dbc-$(date +%F)
cp "$out"/*.dbc /srv/coa/server-data/dbc/
```

`--original` lit les archives intactes `NOM.ORIGINAL` du launcher. Ici le jeu compte 368 tables (patch-M 288,
patch-S 48, archives locales standard 31, patch-T 1). À refaire après une mise à jour du client, puis redémarrer le
worldserver.

`ac-client-data-init` (dépendance des serveurs) télécharge les données standard et les décompresse avec `unzip -o`,
ce qui écraserait les DBC CoA. Il saute le téléchargement quand `data-version` correspond à sa version
(`apps/installer/includes/functions.sh`) ; le fichier ci-dessus utilise ce contrôle existant.

## 9. Configuration

Deux fichiers distincts :

- **`.env` dans le dépôt** (à côté de `docker-compose.yml`, seul endroit où Compose le lit) : mot de passe root
  MySQL, ports, chemins sur l'hôte.
- **`/srv/coa/coa.env`** : réglages serveur injectés dans authserver/worldserver. Il ne doit pas contenir le mot de
  passe.

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
git check-ignore -v .env                  # .gitignore:21:/.env*

cp conf/dist/env.ac /srv/coa/coa.env
cat >> /srv/coa/coa.env <<'EOF'

# CoA settings from the repack (Settings/*.template)
AC_ASCENSION_COMPAT_ALLOW_REMOTE_CLIENTS=1
AC_ASCENSION_MANASTORM_ENABLE=1
AC_PLAYER_START_CUSTOM_SPELLS=1
EOF

for f in modules/*/conf/*.conf.dist; do cp -n "$f" "/srv/coa/etc/modules/$(basename "${f%.dist}")"; done

docker compose config | grep -E "host_ip|source: /srv|AC_ASCENSION|AC_PLAYER_START"
```

- Le mot de passe est généré dans le fichier sans être affiché ; les commandes suivantes le lisent dans le conteneur
  (`$MYSQL_ROOT_PASSWORD`). Éviter `;`, `$`, espaces et guillemets s'il est saisi à la main.
- Noms des variables selon `IniKeyToEnvVarKey` (`src/common/Configuration/Config.cpp`) : préfixe `AC_`, points en
  `_`, `_` entre une minuscule et une majuscule, tout en majuscules.
- `AscensionCompat.DbcDirectory` a été supprimé par #1498 (les collections lisent `dbc/`) : le retirer des anciens
  `coa.env` et `etc/modules/mod_ascension_compat.conf`.
- Les `.conf` des modules sont indispensables : le worldserver ne charge que `etc/modules/<nom>.conf`
  (`modules/CMakeLists.txt` retire le `.dist`), et les conteneurs ne créent que `worldserver.conf`,
  `authserver.conf` et `dbimport.conf`.
- Résultat attendu du contrôle : `host_ip: 127.0.0.1` (×4), sources `/srv/coa/etc`, `/srv/coa/logs`,
  `/srv/coa/server-data`, et les 3 variables CoA pour authserver et worldserver.

## 10. Base de données

```bash
docker compose up -d ac-database
docker compose ps                         # attendre "healthy"

zcat ~/CoaServer/repack/CoA-Repack/Database/Clean/databases.sql.gz \
  | docker compose exec -T ac-database sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD"'

docker compose exec ac-database sh -c 'mysql -uroot -p"$MYSQL_ROOT_PASSWORD" -e "SELECT COUNT(*) FROM acore_world.updates; SELECT COUNT(*) FROM acore_world.creature_template; SELECT id, username FROM acore_auth.account;"'
```

Attendu : `3057`, `31237`, un compte `LOCAL`. L'avertissement `Using a password on the command line` est normal.

Corriger le port du royaume (le dump contient `16085`) et convertir deux empreintes de mises à jour Windows :

```bash
docker compose exec -T ac-database sh -c 'exec mysql -uroot -p"$MYSQL_ROOT_PASSWORD"' <<'SQL'
UPDATE acore_auth.realmlist SET port = 8085 WHERE id = 1;
UPDATE acore_world.updates SET hash = '9AB2C61CBDE30910A9044DE96CC7EF4C64C6D391'
  WHERE name = 'rev_1787754600000000000.sql' AND hash = '563E4DD451533A7E56EF69D7536127BE836026BD';
UPDATE acore_world.updates SET hash = '91203FA3DBE929E388DA88BD0822BFA140355C4B'
  WHERE name = '2026_08_26_01_ascension_appearance_item_templates.sql' AND hash = 'EC1B200FDA9C234431A90717D347F6A42444676F';
SELECT id, address, port FROM acore_auth.realmlist;
SELECT name, hash FROM acore_world.updates
  WHERE name IN ('rev_1787754600000000000.sql', '2026_08_26_01_ascension_appearance_item_templates.sql');
SQL
```

Pourquoi : ces deux fichiers ont des fins de ligne CRLF. L'updater Windows calcule l'empreinte après conversion en
LF ; sous Linux, sur les octets bruts. Une empreinte différente fait **réappliquer** le fichier par `dbimport`
(`src/server/database/Updater/UpdateFetcher.cpp`), et `rev_1787754600000000000.sql` supprime puis réinsère
`playercreateinfo_item`, `playercreateinfo_spell_custom` et `ascension_custom_class_spell`. Le dépôt fait la même
correction (`apps/coa-world/world_data.py`, `reconcile_ledger`). Le script d'installation calcule ces paires depuis le
dépôt au lieu de les coder en dur.

Appliquer les migrations plus récentes que le dump :

```bash
docker compose up ac-db-import 2>&1 | tee /srv/coa/logs/db-import-$(date +%F).log
docker compose ps -a ac-db-import         # Exited (0)
grep -E "Applying|Reapplying|Applied|auto populating" /srv/coa/logs/db-import-$(date +%F).log
```

Observé : 1 mise à jour auth, 1 characters et 5 world appliquées, aucun `Reapplying update`, aucun `auto populating`.

## 11. Démarrer le serveur

```bash
docker compose up -d ac-authserver ac-worldserver
docker compose logs -f ac-worldserver     # attendre "(worldserver-daemon) ready...", Ctrl+C arrête seulement l'affichage
```

Contrôles :

```bash
docker compose logs --no-color ac-worldserver > /srv/coa/logs/worldserver-start-$(date +%F).log
grep -E "Using modules configuration|> mod_ascension|> coa_bugreport|Failed open|Ascension collection data|Unable to open Ascension|World Initialized|worldserver-daemon\) ready" \
  /srv/coa/logs/worldserver-start-$(date +%F).log
docker compose logs --no-color ac-authserver | tail -5
docker compose ps -a
```

Observé :

- `Using modules configuration:` avec `> coa_bugreport.conf` et `> mod_ascension_compat.conf`.
- `Loaded Ascension collection data: 42884 appearances, 202913 item mappings, 2348 item sets, 10678 vanity entries`.
- `WORLD: World Initialized In 0 Minutes 9 Seconds`, puis `(worldserver-daemon) ready...`.
- authserver : `Added realm "AzerothCore" at 127.0.0.1:8085.`
- `ac-client-data-init` et `ac-db-import` se terminent avec le code 0 ; les trois autres conteneurs restent démarrés.

Ce ne sont pas des erreurs :

- `Can't set process priority class, error: Permission denied` : le conteneur n'a pas le droit de changer sa priorité.
- `/srv/coa/logs/Errors.log` (~93 000 lignes) : avertissements de validation des données, surtout des objets custom
  (`wrong LimitCategory`, `item_set_names`, `RandomProperty`) et quelques entrées `spell_proc`/`trainer_spell`.
  Aucune ne mentionne Ascension, CoA ou Manastorm.
- `AscensionCompat.AllowRemoteClients` n'apparaît pas dans les « Found config value … from environment variable » :
  il est lu sans log (`WorldSocket.cpp`), mais la valeur d'environnement est bien utilisée
  (`ConfigMgr::GetValueDefault`). `docker compose exec ac-worldserver printenv | grep AC_ASCENSION` l'affiche.

## 12. Changer le mot de passe du compte GM

Le compte `local`/`local` est publié avec le repack.

```bash
docker compose attach ac-worldserver
```

```
account set password local NOUVEAU_MDP NOUVEAU_MDP
```

La console répond `The password was changed`. Sortir avec **Ctrl+P puis Ctrl+Q** ; Ctrl+C arrête le serveur. La
commande attend le nom du compte et deux fois le mot de passe ; `.account set password …` fonctionne aussi.

## 13. Lancer le client

`Ascension.exe` et `Extensions.dll` sont des binaires Windows 32 bits. Ils tournent avec `umu-run` et GE-Proton
(variables issues de `umu(1)`), **avec `DivxTac.dll` désactivé** :

```bash
cd ~/CoaServer/client/ascension-live
WINEPREFIX="$HOME/Games/umu/coa-client" GAMEID=0 \
PROTONPATH="$HOME/.local/share/Steam/compatibilitytools.d/GE-Proton11-6-x86_64" \
WINEDLLOVERRIDES="divxtac=d" \
umu-run Ascension.exe
```

Vérifié le 2026-09-15 : connexion, création de personnage (classe custom 23) et entrée dans le monde.

- Le lancer depuis le dossier du client (il lit `Data/` à partir de là).
- Suivre le côté serveur avec `docker compose logs -f ac-authserver ac-worldserver`.
- Sans `divxtac=d`, le client se fige sur l'écran de chargement à 100 % (voir [Pièges connus](#pièges-connus)).
  Retirer `DivxTac.dll` du dossier du client a le même effet (signalé par des joueurs Linux sur Discord).

### Lanceur

[`scripts/coa-client`](scripts/coa-client) encapsule cette commande :

```bash
cp scripts/coa-client ~/.local/bin/ && chmod +x ~/.local/bin/coa-client
coa-client            # lancer (sortie dans ~/CoaServer/logs/client.log hors terminal)
coa-client --debug    # lancer avec un log Proton (~/CoaServer/logs/steam-0.log)
coa-client --kill     # arrêter uniquement un client figé
```

Il refuse de lancer un second client et avertit si aucun authserver ne répond sur `127.0.0.1:3724`. Pour une
entrée de menu, copier [`scripts/coa-client.desktop`](scripts/coa-client.desktop) dans `~/.local/share/applications/`,
remplacer `USER`, puis lancer `update-desktop-database ~/.local/share/applications`.

### Déboguer le client

`coa-client --debug` définit `PROTON_LOG=1` : Proton écrit les traces
`+timestamp,+pid,+tid,+seh,+unwind,+threadname,+debugstr,+loaddll`. Ce n'est pas un débogueur attaché ;
`Extensions.dll` contient des contrôles anti-debug, donc éviter les vrais débogueurs. Recherches utiles dans le log :
`trace:loaddll` (dernières DLL chargées avant un blocage), `err:sync` (interblocages, par exemple
`loader_section … blocked by`), `warn:seh`. Un thread qui lève `0x80000003`/`0x80000004` et appelle
`OutputDebugStringA "%s%s…"` toutes les 5 secondes est la surveillance anti-debug du client, pas une erreur.

## Utilisation courante

```bash
cd ~/Projects/azerothcore-wotlk-coa
docker compose up -d ac-authserver ac-worldserver       # démarrer (MySQL et les services ponctuels aussi)
docker compose stop -t 60                               # arrêter ; le worldserver gère SIGTERM (Main.cpp)
docker compose logs -f ac-worldserver                   # suivre les logs
docker compose exec -T ac-database sh -c 'exec mysqldump -uroot -p"$MYSQL_ROOT_PASSWORD" --single-transaction --databases acore_auth acore_characters acore_world' \
  | gzip > /srv/coa/backups/coa-$(date +%F).sql.gz      # sauvegarde
```

`-t 60` laisse au worldserver plus que les 10 secondes par défaut de Docker pour s'arrêter ; le temps réellement
nécessaire n'a pas été mesuré. `mysqldump` 8.4.11 est présent dans l'image `mysql:8.4` ; la commande de sauvegarde
elle-même n'a pas encore été lancée.

## Installation automatisée

[`scripts/setup-coa-server.sh`](scripts/setup-coa-server.sh) exécute les étapes 8 à 11 (plus le build, sauf avec
`--skip-build`), avec contrôles :

```bash
sudo mkdir -p /srv/coa && sudo chown "$(id -u):$(id -g)" /srv/coa
~/Projects/coa-server-guide/scripts/setup-coa-server.sh \
  --repo ~/Projects/azerothcore-wotlk-coa \
  --repack ~/CoaServer/repack/CoA-Repack
```

- Vérifie l'empreinte du dump, avertit si le correctif Boost manque, garde `.env`, `coa.env`, données et configs de
  modules existants, n'importe jamais par-dessus une `acore_world` existante et ne redémarre pas des serveurs déjà
  lancés.
- Convertit toutes les empreintes CRLF trouvées dans le dépôt (conditionnées à l'empreinte Windows), lance
  `dbimport`, échoue sur un code de sortie non nul, avertit sur `Reapplying update`, attend
  `(worldserver-daemon) ready`.
- Ne patche pas le client, ne change pas le mot de passe GM et ne lance pas le client.

## Agents en parallèle : slots de serveur

Une stack ne sert qu'un agent à la fois : un rebuild ou un redémarrage par un agent invalide sans prévenir les tests
d'un autre. [`scripts/coa-slot`](scripts/coa-slot) (lien `~/.local/bin/coa-slot`) fait tourner jusqu'à trois stacks
isolées côte à côte : jusqu'à trois agents corrigent et testent des lots en même temps, sans verrou de serveur
partagé.

| Slot | Projet Compose | Conteneurs | Tag d'image | Ports auth / world / MySQL / SOAP | Config et logs |
|------|----------------|------------|-------------|-----------------------------------|----------------|
| 1 | `azerothcore-wotlk-coa` | `ac-*` | `master` | 3724 / 8085 / 3306 / 7878 | `/srv/coa/etc`, `/srv/coa/logs` |
| 2 | `coa-s2` | `coa-s2-*` | `s2` | 3824 / 8185 / 3406 / 7978 | `~/CoaServer/slots/s2/{etc,logs}` |
| 3 | `coa-s3` | `coa-s3-*` | `s3` | 3924 / 8285 / 3506 / 8078 | `~/CoaServer/slots/s3/{etc,logs}` |

Le slot 1 est le serveur d'origine ; le client de jeu s'y connecte. Chaque slot a aussi son volume de base, son clone
de build `~/Projects/azerothcore-wotlk-coa-build-sN` (`origin` = GitHub, remote `local` = le dépôt principal) et son
fichier d'environnement Ghost `~/CoaServer/slots/sN/ghost.env`. Les données serveur (`/srv/coa/server-data`, en
lecture seule dans les conteneurs) sont partagées, sauf pour un slot créé avec `--own-data`.

```bash
coa-slot list                                 # détenteur, commit déployé et état du worldserver de chaque slot
coa-slot claim 2 "pets batch"                 # prendre un slot libre (échoue s'il est tenu par un autre agent)
coa-slot claim-issues 2 209 285 1425          # réserver des issues (tout ou rien, entre slots)
coa-slot create 2                             # première fois : copie de config, clone, base depuis le dump du repack
coa-slot deploy 2 fix/coa-summons-pets        # checkout dans le clone, build :s2, db-import, redémarrage, attente
coa-slot preflight 2                          # coa-preflight.py sur le slot 2 (mpqcli requis)
set -a; . ~/CoaServer/slots/s2/ghost.env; set +a
go test -tags=e2e -p 1 ./e2e/coa/summonspets -count=1 -v
coa-slot compose 2 logs --tail 50 ac-worldserver
coa-slot stop 2 && coa-slot release 2         # lot terminé
```

- `create` copie `/srv/coa/etc` une fois (les tests Ghost modifient `worldserver.conf`), remplit la base des slots 2
  et 3 depuis le dump du repack comme `setup-coa-server.sh` (port du realm = port world du slot, empreintes CRLF
  converties) et écrit `compose.env`, `compose.override.yml` (noms de conteneurs) et `ghost.env` (ports, chemin DBC,
  chemin de config).
- `deploy` accepte une branche du dépôt principal (branches de worktree comprises, sans push), une branche d'origin ou
  un commit. Un nom de branche présent dans le dépôt principal passe avant origin : déployer `origin/main`, pas
  `main`. Il refuse un clone avec des modifications non commitées et écrit `branche sha date` dans
  `~/CoaServer/slots/sN/state`.
- Le SQL appliqué par une branche reste dans la base du slot. Avant de déployer une branche qui ne l'a pas :
  `coa-slot reset-db N` (slots 2 et 3 seulement).
- `destroy N --yes` (slots 2 et 3, libérés avant) supprime conteneurs, volume de base, images du slot et
  `~/CoaServer/slots/sN`, et garde le clone de build.
- Les réservations sont de simples fichiers : `~/CoaServer/slots/sN/owner` (créé avec `noclobber`) et
  `~/CoaServer/slots/issues.tsv` (mis à jour sous `flock`). Elles coordonnent les agents ; elles ne bloquent pas une
  commande tapée à la main.
- Ressources : un slot démarré utilisait ici environ 5 Gio de RAM (worldserver 3,8 Gio, MySQL 1,3 Gio). Les builds
  de slots différents s'attendent à l'étape de compilation, car le montage ccache du Dockerfile est
  `sharing=locked`.

## Déployer sur un VPS (pas testé)

Même dépôt, même organisation `/srv/coa`. Différences :

1. Ports : `DOCKER_AUTH_EXTERNAL_PORT=3724` et `DOCKER_WORLD_EXTERNAL_PORT=8085` (toutes interfaces) ; MySQL et SOAP
   restent sur `127.0.0.1`. N'ouvrir que 3724/tcp et 8085/tcp dans le pare-feu.
2. Adresse du royaume : `UPDATE acore_auth.realmlist SET address = '<IP publique ou DNS>' WHERE id = 1;`
3. Client : `set realmlist <adresse du serveur>` dans `realmlist.wtf`. Le client patché accepte une adresse monde
   distante (`apps/client-compat/README.md`) et `AllowRemoteClients = 1` est déjà réglé.
4. Images : les construire sur le VPS, ou les pousser sur un registre sous ton propre nom (pas `acore/…`, voir les
   pièges).
5. Données : copier `/srv/coa/server-data` et `coa.env` (`rsync`), puis importer un `mysqldump` fait sur le PC.
6. Sécurité : nouveau mot de passe root MySQL, mot de passe GM changé, système tenu à jour.

## Tests de gameplay automatisés

Le dépôt contient des scénarios de test exécutés dans un worldserver jetable, sur des copies des bases. Depuis la
racine du dépôt, une fois les images serveur construites :

    mkdir -p .cache/coa-gameplay-tests
    docker compose -f docker-compose.yml -f apps/coa-gameplay-test/docker/compose.yml --profile tests \
      build ac-gameplay-test
    docker compose -f docker-compose.yml -f apps/coa-gameplay-test/docker/compose.yml --profile tests \
      run --rm ac-gameplay-test run apps/coa-gameplay-test/scenarios/frostbolt.json

Un run copie les trois bases (environ 3 minutes ici), exécute le scénario puis supprime les copies. Résultats dans
`.cache/coa-gameplay-tests/`. Détails : `apps/coa-gameplay-test/README.md`.

## Pièges connus

- **Ne jamais lancer `docker compose pull`** (ni `./acore.sh docker pull`) : les images compilées portent les mêmes
  noms que les images officielles et seraient remplacées par des versions sans le module CoA.
- **Ne pas lancer `docker compose up` sur tous les services avant les étapes 8 à 10** : création d'une base world
  standard et téléchargement des données standard par-dessus les fichiers CoA.
- **Build cassé depuis la PR #235** (`bb1d48a5f`) : `CoAGameplayTest.cpp` échoue avec
  `fatal error: no member named 'placeholders' in namespace 'boost'`. `deps/boost/CMakeLists.txt` définit
  `BOOST_BIND_NO_PLACEHOLDERS` pour tout le projet, donc le `bind.hpp` de Boost 1.83 n'inclut pas
  `placeholders.hpp`, dont le parseur JSON de Boost.PropertyTree a besoin. Correctif :
  `#include <boost/bind/placeholders.hpp>` avant `<boost/property_tree/json_parser.hpp>`. Vérifié : build Docker
  complet réussi (1 362/1 362). Proposé au fork dans la
  [PR #243](https://github.com/jealous-sound/azerothcore-wotlk-coa/pull/243).
- **`.env` ou `coa.env`** : les réglages Compose (mot de passe, ports, chemins) vont dans le `.env` du dépôt. Tout ce
  qui est dans `coa.env` est injecté dans les conteneurs serveur.
- **Configs de modules manquantes** : sans `etc/modules/*.conf`, les réglages du module retombent silencieusement sur
  les valeurs par défaut du code (par exemple `AscensionCompat.PlaintextWorldHeaders` vaut `false` dans le code et `1`
  dans la config).
- **Empreintes CRLF** : une base créée sous Windows et utilisée par l'updater Linux réapplique les fichiers CRLF si
  leurs empreintes ne sont pas converties (étape 10).
- **Client figé à 100 % sur l'écran de chargement du monde (Wine/Proton)** : à l'entrée dans le monde,
  `Extensions.dll` charge `DivxTac.dll`, un assembly .NET mixte (C++/CLI, `ILONLY=False`, runtime `v4.0.30319`). Wine
  le charge via wine-mono depuis `_CorDllMain` en tenant le verrou de chargement des DLL ; le thread principal ne rend
  jamais la main et tous les autres threads attendent `loader_section` (log Proton : `err:sync … blocked by <thread
  principal>`). Côté serveur le personnage est en ligne, et le client ne lit plus sa connexion. Correctif :
  `WINEDLLOVERRIDES="divxtac=d"` (ou retirer `DivxTac.dll` du dossier du client). Écartés pendant l'enquête : la
  révision du patch client (rev 3 et rev 4 identiques), le snapshot complet du catalogue d'apparences
  (`AscensionCompat.UnlockLocalAppearanceCatalog = 0` ne change rien), les alertes anti-triche (aucune enregistrée),
  la ligne `MemoryBridge … oversized_message` (présente aussi dans d'anciennes sessions).
- **Client Ascension et réseau Docker** : `src/server/game/Server/WorldSocket.cpp` n'active le protocole Ascension
  que pour une connexion en loopback, sauf si `AscensionCompat.AllowRemoteClients = 1`. Derrière le réseau Docker, la
  connexion n'arrive pas de `127.0.0.1` (le serveur voit la passerelle du bridge, par exemple `172.19.0.1`). Tant que
  la [PR #261](https://github.com/jealous-sound/azerothcore-wotlk-coa/pull/261) (issue #260) n'est pas intégrée, le
  format Ascension des modificateurs de sorts et la conversion de la classe 10 exigent encore l'adresse littérale
  `127.0.0.1` : derrière Docker, les modificateurs de talents et passifs manquent dans les infobulles du client (par
  exemple Moon Arrow du Starcaller affiche 30 m au lieu de 45).
- **Les versions doivent aller ensemble** : binaire serveur, base, DBC serveur et patch client. Un binaire plus
  ancien que la base provoque des erreurs du type ACE00004 (`Unknown column ...`).
- **Base CoA incluse dans le dépôt** (`data/coa-world`, `coa-world-20260912`) : plus ancienne que le dump du repack.
  Si on l'utilise quand même, `apps/coa-world/world_data.py bootstrap` exige une base world vide, un client `mysql`
  8.4 (option `--no-login-paths` absente du client 8.0 d'Ubuntu) et Python 3.11+. Testé : `mysql:8.4` +
  `microdnf install -y python3.12` fonctionne.
- **Données client standard d'AzerothCore** : suffisantes pour démarrer le cœur, mais sans les DBC Ascension
  (collections vides, contenu CoA partiel).

## Contribuer

- Il faut les droits d'écriture ou un fork GitHub de `jealous-sound/azerothcore-wotlk-coa` (les contributeurs
  externes ouvrent leurs PR depuis leur fork) :
  `git remote add fork https://github.com/<user>/azerothcore-wotlk-coa.git`.
- Corps de PR selon `.github/pull_request_template.md` : *Problem and resulting behavior*, *Validation and remaining
  limits*, *Data/source dependencies* (confirmer que le SQL appliqué est inchangé, sans identifiants, profils ni
  archives du jeu).
- `.github/CONTRIBUTING.md` : changements ciblés ; distinguer vérifications du code, builds et tests en jeu. GitHub
  Actions ne fait que des vérifications du dépôt, pas de build serveur ; les PR venant d'un fork peuvent attendre
  l'approbation d'un mainteneur pour lancer la CI.
- Titre de commit/PR : `Type(Scope): Subject`, 50 caractères maximum, impératif, majuscule, sans point ; lignes du
  corps limitées à 72 caractères. Tout en anglais. Déclarer l'usage de l'IA.
- Contrôles locaux équivalents à la CI : `python apps/codestyle/codestyle-cpp.py --files <chemin>`,
  `python -B tools/check_repository.py`, `python -B apps/codestyle/tests/test_scoped_lint.py`,
  `python -B modules/mod-ascension-compat/tests/client_compat/run.py`, `git diff --check`.

## Annexe : MCP AzerothCore

[`azerothcore/azerothMCP`](https://github.com/azerothcore/azerothMCP) (Python, SSE sur le port 8080) donne à un
assistant IA un accès aux bases (créatures, SmartAI, quêtes, conditions…). La recherche wiki/source est désactivée
par défaut ; il ne sert qu'avec une base remplie. Audit rapide du commit `dc62b920` : rien de malveillant trouvé,
mais un sandbox Python par `exec()` activé par défaut, une lecture seule vérifiée par préfixe de requête et des
dépendances non figées. Si utilisé : `ENABLE_SANDBOX=false`, utilisateur MySQL `SELECT` seul sans accès à
`acore_auth`, conteneur isolé, commit figé.

## Liens utiles

Projet CoA
- Serveur : <https://github.com/jealous-sound/azerothcore-wotlk-coa>
- Service de rapports de bugs : <https://github.com/jealous-sound/coa-bug-report>
- Kit local (outillage, composants client portables), cité dans `.github/CONTRIBUTING.md` :
  <https://github.com/jealous-sound/coa-local-kit> (erreur 404 le 2026-09-15 : privé ou supprimé)
- mod-playerbots : <https://github.com/jealous-sound/mod-playerbots>
- AzerothCore WotLK avec playerbots : <https://github.com/jealous-sound/azerothcore-wotlk-playerbot>
- PR #235 (harnais de test gameplay) : <https://github.com/jealous-sound/azerothcore-wotlk-coa/pull/235>
- PR #243 (correctif de build Boost) : <https://github.com/jealous-sound/azerothcore-wotlk-coa/pull/243>
- Téléchargements client, patch client et repack : partagés par l'auteur du fork sur le canal Discord du projet (pas
  de lien ici ; les archives du jeu ne doivent pas être redistribuées via le dépôt).

AzerothCore
- Dépôt officiel : <https://github.com/azerothcore/azerothcore-wotlk>
- Vue d'ensemble de l'installation : <https://www.azerothcore.org/wiki/installation>
- Installation Docker : <https://www.azerothcore.org/wiki/install-with-docker>
- Images Docker précompilées (acore-docker) : <https://www.azerothcore.org/acore-docker/>
- Prérequis Linux : <https://www.azerothcore.org/wiki/linux-requirements>
- Configuration serveur Linux (configs, données client) : <https://www.azerothcore.org/wiki/linux-server-setup>
- Installation des bases : <https://www.azerothcore.org/wiki/database-installation>
- Mise à jour des bases : <https://www.azerothcore.org/wiki/database-keeping-the-server-up-to-date>
- Réseau (realmlist, ports) : <https://www.azerothcore.org/wiki/networking>
- Dernières étapes (comptes, GM) : <https://www.azerothcore.org/wiki/final-server-steps>
- Configuration du client : <https://www.azerothcore.org/wiki/client-setup>
- Erreurs courantes : <https://www.azerothcore.org/wiki/common-errors>
- Règles des messages de commit : <https://www.azerothcore.org/wiki/commit-message-guidelines>
- Règles pour l'IA (agentic engineering) : <https://www.azerothcore.org/wiki/agentic-engineering>
- Tester une PR : <https://www.azerothcore.org/wiki/How-to-test-a-PR>
- Données client standard : <https://github.com/wowgaming/client-data/releases>
- Discord : <https://discord.com/invite/GyFvXpk7>

Outils
- MCP AzerothCore : <https://github.com/azerothcore/azerothMCP>
- MCP AzerothCore (blinkysc) : <https://github.com/blinkysc/azerothMCP>
- Discussion MCP via SOAP : <https://github.com/azerothcore/azerothcore-wotlk/discussions/24853>
- Keira3 (éditeur de base) : <https://github.com/azerothcore/Keira3>
- umu-launcher (Proton hors Steam) : <https://github.com/Open-Wine-Components/umu-launcher>

Ascension sous Linux (communauté)
- Guide Ascension sous Linux (Lutris/Wine, désactive `divxtac`) : <https://github.com/Elkenniss/ascension-linux-guide>
- Ascension WoW sous Arch Linux (GE-Proton, surcharge `divxtac`, `PROTON_DISABLE_XALIA`) :
  <https://github.com/Ostekages/Ascension-WoW-on-Arch-Linux>
- Page Lutris : <https://lutris.net/games/ascension-wow/>
