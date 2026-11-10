#!/usr/bin/env bash
# Automatische APT-Updates fuer Debian 13 und Ubuntu 24.04.
# Keine erzwungene Entscheidung bei dpkg-Conffile-Konflikten.
# Nur offizielle Basis-, Updates- und Security-Repositories.
set -Eeuo pipefail

readonly APT_CONF='/etc/apt/apt.conf.d/99zz-local-unattended-upgrades'
readonly NEEDRESTART_CONF='/etc/needrestart/conf.d/99zz-local-list-only.conf'
readonly SERVICE_DROPIN='/etc/systemd/system/apt-daily-upgrade.service.d/99zz-needrestart-list-only.conf'
readonly STAMP="$(date -u +%Y%m%dT%H%M%SZ)"

log()  { printf '[INFO] %s\n' "$*"; }
warn() { printf '[WARNUNG] %s\n' "$*" >&2; }
fail() { printf '[FEHLER] %s\n' "$*" >&2; exit 1; }
trap 'warn "Abbruch in Zeile $LINENO. Eventuelle bestehende Sicherungen tragen das Suffix .bak.*"' ERR

[[ ${EUID} -eq 0 ]] || fail 'Bitte als root ausfuehren (sudo bash ...).'
[[ -r /etc/os-release ]] || fail '/etc/os-release fehlt.'
# shellcheck source=/etc/os-release
source /etc/os-release

case "${ID}:${VERSION_ID}" in
  debian:13) OS='Debian 13'; CODENAME='trixie' ;;
  ubuntu:24.04) OS='Ubuntu 24.04'; CODENAME='noble' ;;
  *) fail "Nicht unterstuetzt: ${PRETTY_NAME:-${ID} ${VERSION_ID}}. Nur Debian 13 und Ubuntu 24.04." ;;
esac
[[ ${VERSION_CODENAME:-} == "$CODENAME" ]] || fail 'Unerwarteter Distributions-Codename.'
command -v apt-get >/dev/null || fail 'apt-get nicht gefunden.'
command -v apt-config >/dev/null || fail 'apt-config nicht gefunden.'
command -v dpkg >/dev/null || fail 'dpkg nicht gefunden.'
log "Erkanntes System: $OS ($CODENAME)"

# Bereits vorhandene globale dpkg-Force-Optionen wuerden das
# Zurueckstellen von Conffile-Konflikten verhindern.
assert_no_force_conf() {
  local opts
  opts="$(apt-config dump | grep -i '^Dpkg::Options' || true)"
  if grep -Eiq -- 'force-conf(old|new|def|miss|ask)' <<< "$opts"; then
    printf '%s\n' "$opts" >&2
    fail 'APT erzwingt bereits dpkg-Conffile-Entscheidungen. Bitte vorher manuell entfernen.'
  fi
  local cfg_files=()
  [[ ! -f /etc/dpkg/dpkg.cfg ]] || cfg_files+=(/etc/dpkg/dpkg.cfg)
  if [[ -d /etc/dpkg/dpkg.cfg.d ]]; then
    while IFS= read -r -d '' cfg; do cfg_files+=("$cfg"); done < <(find /etc/dpkg/dpkg.cfg.d -maxdepth 1 -type f -print0)
  fi
  if ((${#cfg_files[@]})) && grep -iE '^[[:space:]]*(-{0,2})?force-conf(old|new|def|miss|ask)([[:space:]]|$)' "${cfg_files[@]}"; then
    fail 'In /etc/dpkg sind erzwungene Conffile-Entscheidungen hinterlegt.'
  fi
}
assert_no_force_conf

if [[ -n "$(dpkg --audit)" ]]; then
  dpkg --audit >&2
  fail 'Die dpkg-Datenbank ist nicht sauber. Bitte erst manuell reparieren.'
fi

# Schreibt nur bei inhaltlicher Aenderung; vorhandene eigene Drop-ins
# werden vorher gesichert. Paketverwaltete Dateien bleiben unangetastet.
write_config() {
  local target="$1" directory tmp
  directory="$(dirname "$target")"
  install -d -m 0755 "$directory"
  tmp="$(mktemp "${directory}/.unattended-tmp.XXXXXXXX")"
  cat > "$tmp"
  chmod 0644 "$tmp"
  chown root:root "$tmp"
  if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
    rm -f "$tmp"
    log "Unveraendert: $target"
  else
    if [[ -e "$target" ]]; then
      cp -a -- "$target" "${target}.bak.${STAMP}"
      log "Sicherung: ${target}.bak.${STAMP}"
    fi
    mv -f -- "$tmp" "$target"
    log "Geschrieben: $target"
  fi
}

# Vor dem Installationslauf setzen, damit needrestart (falls bereits
# installiert) nicht automatisch Dienste neustartet.
write_config "$NEEDRESTART_CONF" <<'NEEDRESTART'
# Von setup-unattended-upgrades.sh verwaltet.
# Dienste nur melden, nicht durch needrestart neu starten.
$nrconf{restart} = 'l';
NEEDRESTART

# Auch bei Ubuntu 24.04 den Modus im systemd-APT-Prozess explizit setzen.
# Damit gilt er fuer needrestart im geerbten Prozessumfeld.
write_config "$SERVICE_DROPIN" <<'SYSTEMD'
[Service]
Environment="NEEDRESTART_MODE=l"
SYSTEMD

log 'Paketlisten aktualisieren und benoetigte Pakete installieren ...'
# Hier werden keine Dpkg::Options wie --force-confold/new/def gesetzt.
# Der Installationslauf kann im Konfliktfall abbrechen; das ist beabsichtigt.
export DEBIAN_FRONTEND=noninteractive
export NEEDRESTART_MODE=l
apt-get update
apt-get install -y --no-install-recommends unattended-upgrades needrestart

log 'Automatische Updates konfigurieren ...'
# Die von Distribution/Paketen gelieferten Dateien werden nicht editiert.
# #clear ist erforderlich, weil APT-Listen sonst nur ergaenzt werden.
if [[ "$ID" == 'debian' ]]; then
  write_config "$APT_CONF" <<'APT_DEBIAN'
// Von setup-unattended-upgrades.sh verwaltet.
// Debian 13: normales trixie, trixie-updates und Security.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Debian,codename=trixie,label=Debian";
    "origin=Debian,codename=trixie-updates,label=Debian";
    "origin=Debian,codename=trixie,label=Debian-Security";
    "origin=Debian,codename=trixie-security,label=Debian-Security";
};
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::AutoFixInterruptedDpkg "false";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::SyslogEnable "true";
APT_DEBIAN
else
  write_config "$APT_CONF" <<'APT_UBUNTU'
// Von setup-unattended-upgrades.sh verwaltet.
// Ubuntu 24.04: noble, noble-updates, noble-security und aktivierte ESM-Security.
#clear Unattended-Upgrade::Allowed-Origins;
#clear Unattended-Upgrade::Origins-Pattern;
Unattended-Upgrade::Origins-Pattern {
    "origin=Ubuntu,archive=noble,label=Ubuntu";
    "origin=Ubuntu,archive=noble-updates,label=Ubuntu";
    "origin=Ubuntu,archive=noble-security,label=Ubuntu";
    // Ubuntu Pro ESM: wirksam nur bei aktivierten ESM-Repositories.
    "origin=UbuntuESMApps,archive=noble-apps-security";
    "origin=UbuntuESM,archive=noble-infra-security";
};
APT::Periodic::Enable "1";
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::AutoFixInterruptedDpkg "false";
Unattended-Upgrade::Automatic-Reboot "false";
Unattended-Upgrade::Remove-New-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Dependencies "false";
Unattended-Upgrade::Remove-Unused-Kernel-Packages "false";
Unattended-Upgrade::InstallOnShutdown "false";
Unattended-Upgrade::SyslogEnable "true";
APT_UBUNTU
fi

# Effektive APT-Konfiguration verifizieren, auch wenn andere APT-Drop-ins
# in einer spaeter sortierten Datei unsere Einstellungen ueberschreiben.
log 'Wirksame APT-Konfiguration pruefen ...'
assert_no_force_conf
cfg="$(apt-config dump)" || fail 'apt-config dump fehlgeschlagen.'
check_setting() {
  local setting="$1" value="$2"
  grep -Fqi -- "${setting} \"${value}\";" <<< "$cfg" || fail "APT-Einstellung ist nicht wie erwartet: ${setting}=${value}"
}
check_setting 'APT::Periodic::Enable' '1'
check_setting 'APT::Periodic::Update-Package-Lists' '1'
check_setting 'APT::Periodic::Unattended-Upgrade' '1'
check_setting 'Unattended-Upgrade::AutoFixInterruptedDpkg' 'false'
check_setting 'Unattended-Upgrade::Automatic-Reboot' 'false'
check_setting 'Unattended-Upgrade::Remove-New-Unused-Dependencies' 'false'
check_setting 'Unattended-Upgrade::Remove-Unused-Dependencies' 'false'
check_setting 'Unattended-Upgrade::Remove-Unused-Kernel-Packages' 'false'

if grep -Eiq '^Unattended-Upgrade::Allowed-Origins::' <<< "$cfg"; then
  fail 'Unerwartete zusaetzliche Allowed-Origins (andere APT-Drop-ins).'
fi
mapfile -t actual_origins < <(printf '%s\n' "$cfg" | sed -n 's/^Unattended-Upgrade::Origins-Pattern:: "\(.*\)";$/\1/p')
if [[ "$ID" == 'debian' ]]; then
  expected_origins=(
    'origin=Debian,codename=trixie,label=Debian'
    'origin=Debian,codename=trixie-updates,label=Debian'
    'origin=Debian,codename=trixie,label=Debian-Security'
    'origin=Debian,codename=trixie-security,label=Debian-Security'
  )
else
  expected_origins=(
    'origin=Ubuntu,archive=noble,label=Ubuntu'
    'origin=Ubuntu,archive=noble-updates,label=Ubuntu'
    'origin=Ubuntu,archive=noble-security,label=Ubuntu'
    'origin=UbuntuESMApps,archive=noble-apps-security'
    'origin=UbuntuESM,archive=noble-infra-security'
  )
fi
[[ ${#actual_origins[@]} -eq ${#expected_origins[@]} ]] || fail 'Die effektiven Origins-Pattern weichen von der Vorgabe ab.'
for expected in "${expected_origins[@]}"; do
  printf '%s\n' "${actual_origins[@]}" | grep -Fxq -- "$expected" || fail "Origin fehlt: $expected"
done

if [[ -d /run/systemd/system ]]; then
  log 'systemd-Timer aktivieren ...'
  systemctl daemon-reload
  systemctl enable --now apt-daily.timer apt-daily-upgrade.timer
  log 'Timer aktiviert: apt-daily.timer und apt-daily-upgrade.timer.'
else
  warn 'systemd laeuft hier nicht als Init-System. Timer konnten nicht aktiviert werden.'
fi

log 'Konfigurationstest (keine echte Paketinstallation) ...'
if unattended-upgrade --dry-run --debug; then
  log 'Test erfolgreich.'
else
  warn 'Der Dry-Run schlug fehl. Bitte Logs und Repositories pruefen.'
  exit 1
fi

printf '\n[OK] %s: taegliche automatische Paket- und Sicherheitsupdates sind eingerichtet.\n' "$OS"
printf '     Config-Datei: %s\n' "$APT_CONF"
printf '     APT-Log:      /var/log/unattended-upgrades/unattended-upgrades.log\n'
printf '     Verifikation: apt-config dump | grep -E "^(APT::Periodic|Unattended-Upgrade)"\n'
printf '     Timer:        systemctl list-timers "apt-daily*"\n'
printf '\nHinweis: Conffile-Konflikte werden zurueckgestellt, nicht automatisch aufgeloest.\n'
printf 'Paket-Maintainer-Skripte koennen dennoch Dateien aendern oder Dienste neustarten.\n'
