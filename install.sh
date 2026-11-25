#!/usr/bin/env bash
# Kijkbord installeren op Proxmox VE.
# Uitvoeren in de shell van de Proxmox-host (als root):
#
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/sagten88/kijkbord-installer/main/install.sh)"
#
# Maakt een Debian 13-container, zet Kijkbord erin en stelt automatische updates in.
# Alleen versies met een geldige handtekening van de uitgever worden geïnstalleerd, nu en bij elke update.
#
# Tijdens de gesloten test is de code privé: deze server krijgt dan een eigen sleutel die alleen mag
# lezen. Die sleutel stuur je naar de beheerder van Kijkbord, die hem toevoegt.
set -euo pipefail

REPO_HTTPS="https://github.com/sagten88/kijkbord.git"
REPO_SSH="git@github.com:sagten88/kijkbord.git"
PORT=3100

# Alleen versies met deze handtekening worden geïnstalleerd (dezelfde uitgever als Kijkbox).
ALLOWED_SIGNERS='release@agtenhosting namespaces="git" ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIJ/JQkEyguheAlzgd1t9/UpeSjQliolmtkJmL64alr8D'

# De officiële serversleutels van GitHub (https://api.github.com/meta).
GITHUB_KNOWN_HOSTS='github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl
github.com ecdsa-sha2-nistp256 AAAAE2VjZHNhLXNoYTItbmlzdHAyNTYAAAAIbmlzdHAyNTYAAABBBEmKSENjQEezOmxkZMy7opKgwFB9nkt5YRrYMjNuG5N87uRgg6CLrbo5wAdT/y6v0mKV0U2w0WZ2YB/++Tpockg=
github.com ssh-rsa AAAAB3NzaC1yc2EAAAADAQABAAABgQCj7ndNxQowgcQnjshcLrqPEiiphnt+VTTvDP6mHBL9j1aNUkY4Ue1gvwnGLVlOhGeYrnZaMgRK6+PKCUXaDbC7qtbW8gIkhL7aGCsOr/C56SJMy/BCZfxd1nWzAOxSDPgVsmerOBYfNqltV9/hWCqBywINIR+5dIg6JTJ72pcEpEjcYgXkE2YEFXV1JHnsKgbLWNlhScqb2UmyRkQyytRLtL+38TGxkxCflmO+5Z8CSSNY7GidjMIZ7Q4zMjA2n1nGrlTDkzwDCsw+wqFPGQA179cnfGWOWRVruj16z6XyvxvjJwbz0wQZ75XK5tKSb7FNyeIEs4TT4jk+S4dhPeAUC5y+bDYirYgM4GC7uEnztnZyaVWQ7B381AK4Qdrwt51ZqExKbQpTUNn+EjqoTwvqNj4kqx5QUCI0ThS/YkOxJCXmPUWZbhjpCg56i+2aB6CmK2JGhn57K5mj0MNdBXA4/WnwH6XoPWJzK5Nyu2zB3nAZp+S5hpQs+p1vN1/wsjk='

say()  { printf '\n\033[1;33m==> %s\033[0m\n' "$*"; }
fail() { printf '\n\033[1;31mFout: %s\033[0m\n' "$*" >&2; exit 1; }
ask()  { local answer; read -r -p "$1 [$2]: " answer </dev/tty; echo "${answer:-$2}"; }
in_ct() { pct exec "$CTID" -- "$@"; }

[ "$(id -u)" -eq 0 ] || fail "voer dit uit als root op de Proxmox-host."
command -v pct >/dev/null && command -v pveam >/dev/null || fail "dit is geen Proxmox VE-host."

cat <<'EOF'

  Kijkbord installeren
  --------------------
  Dit maakt een nieuwe container met Kijkbord. Druk bij elke vraag op Enter voor de standaardwaarde.

EOF

CTID="$(ask 'Containernummer' "$(pvesh get /cluster/nextid)")"
pct status "$CTID" >/dev/null 2>&1 && fail "container $CTID bestaat al."
NAME="$(ask 'Naam' 'kijkbord')"
CORES="$(ask 'Processorkernen' '1')"
MEMORY="$(ask 'Geheugen in MB' '512')"
DISK="$(ask 'Schijfruimte in GB' '4')"
STORAGES="$(pvesm status -content rootdir -enabled 2>/dev/null | awk 'NR > 1 { print $1 }' | xargs)"
[ -n "$STORAGES" ] || fail "geen opslag gevonden waar containers op kunnen."
STORAGE="$(ask "Opslag voor de container ($STORAGES)" "$(echo "$STORAGES" | cut -d' ' -f1)")"
BRIDGE="$(ask 'Netwerkbrug' 'vmbr0')"
IP="$(ask 'IP-adres (dhcp, of bijvoorbeeld 192.168.1.51/24)' 'dhcp')"
NET="name=eth0,bridge=$BRIDGE,ip=$IP"
if [ "$IP" != "dhcp" ]; then
  GATEWAY="$(ask 'Gateway (router)' "$(ip route | awk '/^default/ { print $3; exit }')")"
  NET="$NET,gw=$GATEWAY"
fi

say "Debian 13-sjabloon ophalen"
pveam update >/dev/null
# Het sjabloon moet bij de processor van de host passen (amd64 of arm64); er staan er meerdere in de lijst.
ARCH="$(dpkg --print-architecture)"
TEMPLATE="$(pveam available --section system | awk -v arch="$ARCH" '$2 ~ ("^debian-13-standard_.*_" arch "\\.tar") { print $2 }' | sort -V | tail -1)"
[ -n "$TEMPLATE" ] || fail "geen Debian 13-sjabloon voor $ARCH gevonden."
echo "Sjabloon: $TEMPLATE"
TSTORE="$(pvesm status -content vztmpl -enabled | awk 'NR > 1 { print $1; exit }')"
pveam list "$TSTORE" | grep -q "$TEMPLATE" || pveam download "$TSTORE" "$TEMPLATE" >/dev/null

say "Container $CTID aanmaken"
pct create "$CTID" "$TSTORE:vztmpl/$TEMPLATE" \
  --hostname "$NAME" --cores "$CORES" --memory "$MEMORY" --swap 256 \
  --rootfs "$STORAGE:$DISK" --net0 "$NET" \
  --unprivileged 1 --features nesting=1 --onboot 1 --ostype debian --arch "$ARCH" --timezone host \
  --description "Kijkbord: een bord voor thuis" >/dev/null
pct start "$CTID"

say "Wachten op internet in de container"
for _ in $(seq 1 60); do in_ct getent hosts github.com >/dev/null 2>&1 && break; sleep 2; done
in_ct getent hosts github.com >/dev/null 2>&1 || fail "de container heeft geen internet. Controleer het netwerk en probeer opnieuw."

say "Basisonderdelen installeren"
# openssh-client is nodig voor ssh-keygen: daarmee controleert git de handtekening van een versie.
in_ct bash -c 'apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq git openssh-client ca-certificates locales >/dev/null'

say "Sleutel van de uitgever klaarzetten"
in_ct install -d -m 0700 /etc/kijkbord
printf '%s\n' "$ALLOWED_SIGNERS" | in_ct bash -c 'cat > /etc/kijkbord/allowed_signers'

if in_ct env GIT_TERMINAL_PROMPT=0 git -c credential.helper= ls-remote --exit-code --tags "$REPO_HTTPS" >/dev/null 2>&1; then
  # De code is openbaar: gewoon via https.
  say "Kijkbord ophalen (alleen versies met een geldige handtekening)"
  in_ct env GIT_TERMINAL_PROMPT=0 git clone --quiet "$REPO_HTTPS" /opt/kijkbord-src \
    || fail "Kijkbord ophalen van GitHub lukte niet. Controleer de internetverbinding en probeer opnieuw (container $CTID blijft bestaan; verwijderen: pct destroy $CTID --purge)."
else
  # Gesloten test: een eigen sleutel voor deze server, alleen om te lezen.
  say "Sleutel voor deze server maken"
  printf '%s\n' "$GITHUB_KNOWN_HOSTS" | in_ct bash -c 'cat > /etc/kijkbord/known_hosts'
  in_ct ssh-keygen -q -t ed25519 -N '' -C "kijkbord-$(hostname)-ct$CTID" -f /etc/kijkbord/deploy_key
  PUBKEY="$(in_ct cat /etc/kijkbord/deploy_key.pub)"
  GIT_SSH='ssh -i /etc/kijkbord/deploy_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes -o UserKnownHostsFile=/etc/kijkbord/known_hosts'

  cat <<EOF

  ┌──────────────────────────────────────────────────────────────────────────┐
  │  Stuur deze sleutel naar de beheerder van Kijkbord. Daarmee mag deze     │
  │  server de code ophalen en updates ontvangen (alleen lezen).             │
  └──────────────────────────────────────────────────────────────────────────┘

$PUBKEY

EOF
  while :; do
    read -r -p "Druk op Enter zodra de beheerder hem heeft toegevoegd (of typ q om te stoppen): " answer </dev/tty
    [ "$answer" = "q" ] && fail "gestopt. Container $CTID blijft bestaan; verwijder hem met: pct destroy $CTID --purge"
    if in_ct env GIT_SSH_COMMAND="$GIT_SSH" git ls-remote --exit-code --tags "$REPO_SSH" >/dev/null 2>&1; then break; fi
    echo "Nog geen toegang. Is de sleutel toegevoegd? Probeer het zo nog eens."
  done

  say "Kijkbord ophalen (alleen versies met een geldige handtekening)"
  in_ct env GIT_SSH_COMMAND="$GIT_SSH" git clone --quiet "$REPO_SSH" /opt/kijkbord-src \
    || fail "Kijkbord ophalen van GitHub lukte niet. Probeer opnieuw (container $CTID blijft bestaan; verwijderen: pct destroy $CTID --purge)."
  in_ct git -C /opt/kijkbord-src config core.sshCommand "$GIT_SSH"
fi

in_ct bash -c '
  cd /opt/kijkbord-src
  for tag in $(git tag -l "v[0-9]*" --sort=-v:refname); do
    if git -c gpg.format=ssh -c gpg.ssh.allowedSignersFile=/etc/kijkbord/allowed_signers verify-tag "$tag" >/dev/null 2>&1; then
      git -c advice.detachedHead=false checkout --quiet "$tag" && echo "Versie ${tag#v}" && exit 0
    fi
  done
  echo "Geen versie met een geldige handtekening gevonden." >&2
  exit 1
'

say "Kijkbord installeren"
OUTPUT="$(in_ct bash /opt/kijkbord-src/deploy/install-container.sh | tee /dev/tty)"
CODE="$(printf '%s\n' "$OUTPUT" | sed -n 's/^KIJKBORD_SETUP_CODE=//p' | tail -1)"
ADDRESS="$(in_ct hostname -I | awk '{ print $1 }')"

cat <<EOF

  ✔ Kijkbord is geïnstalleerd in container $CTID.

  Open:              http://$ADDRESS:$PORT
  Installatiecode:   ${CODE:-zie: pct exec $CTID -- journalctl -u kijkbord | grep Installatiecode}

  Kies met die code een wachtwoord voor de beheerder. Vul daarna bij Instellingen je adres,
  agenda's, afval en verjaardagen in.

  Op de tv of tablet: open de schermlink uit Instellingen > Schermen. Dat scherm blijft daarna
  gekoppeld, zonder wachtwoord.

  Kijkbord werkt alleen op je thuisnetwerk.

  Updates gaan vanzelf, elke nacht. Meteen bijwerken kan in de container:  kijkbord-update install

EOF
