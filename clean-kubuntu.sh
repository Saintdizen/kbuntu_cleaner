#!/usr/bin/env bash
#
# clean-kubuntu.sh — уборка мусора в Kubuntu / Ubuntu + KDE Plasma.
#
# По умолчанию работает в режиме "dry-run": только показывает, что было бы удалено.
# Реальное удаление включается ключом --apply.
#
# Примеры:
#   ./clean-kubuntu.sh                  # показать план (ничего не удаляет)
#   ./clean-kubuntu.sh --apply          # выполнить уборку
#   ./clean-kubuntu.sh --apply --yes    # без подтверждений
#   ./clean-kubuntu.sh --apply --user --snap
#   ./clean-kubuntu.sh --list           # список задач
#

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"

# ------------------------------------------------------------------ настройки
DRY_RUN=1
ASSUME_YES=0
JOURNAL_MAX_SIZE="${JOURNAL_MAX_SIZE:-200M}"
TMP_KEEP_DAYS="${TMP_KEEP_DAYS:-7}"
# Docker: образы старше N часов считаются неиспользуемыми; тома не трогаем
# без явного --docker-volumes (это необратимая потеря данных).
DOCKER_KEEP_HOURS="${DOCKER_KEEP_HOURS:-168}"
DOCKER_PRUNE_VOLUMES=0

# ------------------------------------------------------------------ утилиты
if [[ -t 1 ]]; then
  C_RED=$'\033[1;31m'; C_YEL=$'\033[1;33m'
  C_BLU=$'\033[1;34m'; C_DIM=$'\033[2m'; C_RST=$'\033[0m'
else
  C_RED=''; C_YEL=''; C_BLU=''; C_DIM=''; C_RST=''
fi

log()  { printf '%s==>%s %s\n' "$C_BLU" "$C_RST" "$*"; }
warn() { printf '%s[!]%s %s\n' "$C_YEL" "$C_RST" "$*" >&2; }
err()  { printf '%s[x]%s %s\n' "$C_RED" "$C_RST" "$*" >&2; }
dim()  { printf '%s    %s%s\n' "$C_DIM" "$*" "$C_RST"; }

have() { command -v "$1" >/dev/null 2>&1; }

# Печатает только те из переданных имён пакетов, что реально установлены.
installed_pkgs() {
  local n st
  for n in "$@"; do
    # Без пайпа в grep -q: тот закрывает pipe раньше чтения, и при pipefail
    # пайплайн получает SIGPIPE-статус — установленный пакет ошибочно
    # считался бы отсутствующим.
    st="$(dpkg-query -W -f='${Status}' "$n" 2>/dev/null)" || continue
    [[ "$st" == *'install ok installed'* ]] && printf '%s\n' "$n"
  done
  return 0
}

# Выполнить команду (или напечатать её в dry-run).
run() {
  if (( DRY_RUN )); then
    dim "dry-run: $*"
  else
    dim "\$ $*"
    "$@"
  fi
}

# Удалить пути (учитывает права/существование, показывает размер).
rm_paths() {
  local p size
  for p in "$@"; do
    [[ -e "$p" ]] || continue
    size="$(du -sh -- "$p" 2>/dev/null | cut -f1)"
    if (( DRY_RUN )); then
      dim "dry-run: rm -rf '$p'  (${size:-?})"
    else
      dim "rm -rf '$p'  (${size:-?})"
      rm -rf -- "$p"
    fi
  done
}

# ------------------------------------------------------------------ задачи
# Пользовательские
task_trash()      { log "Корзина"
                    rm_paths "$HOME/.local/share/Trash/files" "$HOME/.local/share/Trash/expunge" \
                             "$HOME/.local/share/Trash/directorysizes"
                    if (( DRY_RUN )); then
                      dim "dry-run: очистить '$HOME/.local/share/Trash/info'"
                    else
                      find "$HOME/.local/share/Trash/info" -mindepth 1 -type f -delete 2>/dev/null || true
                    fi; }
task_thumbnails() { log "Кеш миниатюр";          rm_paths "$HOME/.cache/thumbnails"; }
task_fontcache()  { log "Кеш шрифтов"
                    rm_paths "$HOME/.cache/fontconfig"
                    if (( ! DRY_RUN )); then
                      { have fc-cache && fc-cache -f; } >/dev/null 2>&1 || true
                      systemctl --user restart plasma-plasmashell.service 2>/dev/null || true
                    fi; }
task_recent()     { log "Недавние документы";    rm_paths "$HOME/.local/share/RecentDocuments"; }
task_baloo()      { log "Индекс поиска Baloo"
                    if have balooctl6; then run balooctl6 purge; elif have balooctl; then run balooctl purge; else warn "balooctl не найден"; fi; }
task_browsercache() {
  log "Кеши браузеров"
  local base d
  local -a roots=(
    "$HOME/.cache/mozilla/firefox" "$HOME/.cache/chromium"
    "$HOME/.cache/google-chrome" "$HOME/.cache/BraveSoftware"
    "$HOME/.cache/opera" "$HOME/.cache/vivaldi" "$HOME/.cache/yandex-browser"
  )
  # Удаляются только каталоги кеша внутри профилей: сами профили, Local State
  # и закладки остаются на месте (раньше сносился корень кеша целиком).
  for base in "${roots[@]}"; do
    [[ -d "$base" ]] || continue
    while IFS= read -r -d '' d; do
      rm_paths "$d"
    done < <(find "$base" -mindepth 1 -maxdepth 3 -type d \( \
               -name 'Cache' -o -name 'cache2' -o -name 'Code Cache' \
               -o -name 'GPUCache' -o -name 'ShaderCache' -o -name 'CacheStorage' \
               -o -name 'startupCache' -o -name 'thumbnails' \
             \) -print0 2>/dev/null)
  done
}

# Системные
task_apt() {
  log "APT: кеш пакетов, автоочистка, осиротевшие пакеты"
  run "${SUDO[@]}" apt-get -y autoremove --purge
  run "${SUDO[@]}" apt-get -y clean
  # пакеты, удалённые, но оставившие конфиги (состояние 'rc')
  local -a pkg
  mapfile -t pkg < <(dpkg-query -W -f='${db:Status-Abbrev} ${Package}\n' 2>/dev/null | awk '$1 ~ /^rc/ {print $2}')
  if ((${#pkg[@]})); then
    dim "лишние конфиги: ${#pkg[@]} шт."
    run "${SUDO[@]}" apt-get -y purge "${pkg[@]}"
  fi
}
task_kernels() {
  log "Старые ядра"
  local current newest v pkg
  local -a all to_purge
  current="$(uname -r)"
  # Версионные образы ядра, включая варианты linux-image-unsigned-...
  mapfile -t all < <(dpkg-query -W -f='${Package}\n' 'linux-image-*' 2>/dev/null \
                       | grep -E '^linux-image-(unsigned-)?[0-9]' | sort -V)
  ((${#all[@]})) || { dim "нечего чистить"; return 0; }
  # «Самый новый» сравниваем по версии, а не по имени пакета: иначе unsigned-
  # вариант посчитался бы отдельным ядром и новейший образ мог не сохраниться.
  newest="$(printf '%s\n' "${all[@]}" | sed -E 's/^linux-image-(unsigned-)?//' | sort -V | tail -n1)"
  for pkg in "${all[@]}"; do
    v="${pkg#linux-image-}"; v="${v#unsigned-}"
    [[ "$v" == "$current" || "$v" == "$newest" ]] && continue
    # purge только реально установленных пакетов: apt-get отказывается удалять
    # что-либо, если хотя бы одного имени нет, и ядро тогда остаётся на месте.
    mapfile -t to_purge < <(installed_pkgs \
      "$pkg" "linux-headers-$v" "linux-headers-${v%-*}" \
      "linux-modules-$v" "linux-modules-extra-$v")
    ((${#to_purge[@]})) || continue
    run "${SUDO[@]}" apt-get -y purge "${to_purge[@]}"
  done
}
task_journal() {
  log "Журнал systemd (оставить <= $JOURNAL_MAX_SIZE)"
  run "${SUDO[@]}" journalctl --vacuum-size="$JOURNAL_MAX_SIZE"
}
task_tmp() {
  log "Временные файлы в /tmp и /var/tmp старше $TMP_KEEP_DAYS дней"
  # Служебные каталоги (X11/ICE/font, systemd-private, snap, активные сессии)
  # пропускаем: иначе долгая сессия теряет сокеты и авторизацию.
  run "${SUDO[@]}" find /tmp /var/tmp -xdev -mindepth 1 -maxdepth 1 \
      \( -name '.X*-lock' -o -name '.X11-unix' -o -name '.ICE-unix' \
         -o -name '.XIM-unix' -o -name '.font-unix' -o -name '.Test-unix' \
         -o -name 'systemd-private-*' -o -name 'snap-private-tmp' \
         -o -name 'ssh-*' -o -name 'kde-*' -o -name 'kmail-*' \
      \) -prune -o -mtime "+$TMP_KEEP_DAYS" -exec rm -rf -- {} +
}
task_snap() {
  log "Snap: отключённые ревизии"
  have snap || { dim "snap не установлен"; return 0; }
  local name rev
  while read -r name rev; do
    [[ -n "$name" ]] || continue
    run "${SUDO[@]}" snap remove --revision "$rev" "$name"
  done < <(snap list --all 2>/dev/null | awk '/disabled/ {print $1, $3}')
}
task_flatpak() {
  log "Flatpak: неиспользуемые среды выполнения"
  have flatpak || { dim "flatpak не установлен"; return 0; }
  # без --system чистится только пользовательская инсталляция
  run flatpak uninstall --unused -y
  if (( EUID == 0 )); then
    run flatpak uninstall --unused -y --system
  elif ((${#SUDO[@]})); then
    run "${SUDO[@]}" flatpak uninstall --unused -y --system
  else
    dim "sudo недоступен: системные runtime не проверяются"
  fi
}
task_docker() {
  log "Docker: остановленные контейнеры, старые образы, кеш сборки"
  have docker || { dim "docker не установлен"; return 0; }
  if (( ! DRY_RUN )) && ! docker info >/dev/null 2>&1; then
    warn "нет доступа к Docker (нужен root или группа docker)"
    return 0
  fi
  # Вместо `system prune -af --volumes`: образы с активным контейнером и все
  # тома по умолчанию остаются, удаляется только заведомо мусорное.
  run docker container prune -f
  run docker image prune -af --filter "until=${DOCKER_KEEP_HOURS}h"
  run docker builder prune -af --filter "until=${DOCKER_KEEP_HOURS}h"
  if (( DOCKER_PRUNE_VOLUMES )); then
    warn "удаление ВСЕХ неиспользуемых томов — данные будут потеряны"
    run docker volume prune -f
  else
    dim "тома не трогаем (для удаления добавьте --docker-volumes)"
  fi
}

# Группы
USER_TASKS=(trash thumbnails fontcache recent)
SYSTEM_TASKS=(apt kernels journal tmp)
EXTRA_TASKS=(snap flatpak)
# Не входит ни в одну группу: включается только своим флагом
OPTIONAL_TASKS=(docker baloo browsercache)

TASKS=()

usage() {
  cat <<EOF
$SCRIPT_NAME — уборка мусора в Kubuntu.

Использование:
  $SCRIPT_NAME [режим] [задачи...]

Режим:
  -n, --dry-run     только показать план (по умолчанию)
      --apply       реально удалять
  -y, --yes         не спрашивать подтверждения
      --list        показать доступные задачи и выйти
  -h, --help        эта справка

Задачи (по одной или группами):
  --user            корзина, миниатюры, кеш шрифтов, недавние  [$HOME]
  --system          apt, ядра, журнал, /tmp                     [нужен sudo]
  --snap            старые ревизии snap
  --flatpak         неиспользуемые runtime flatpak
  --docker          остановленные контейнеры, образы и кеш сборки старше 7 дней
  --docker-volumes  вместе с --docker удалить неиспользуемые тома (данные!)
  --trash --thumbnails --fontcache --recent --baloo --browsercache
  --apt --kernels --journal --tmp

Тонкая настройка:
  --journal-size=SIZE   сколько журнала оставлять (сейчас $JOURNAL_MAX_SIZE)
  --tmp-days=N          возраст временных файлов в /tmp (сейчас $TMP_KEEP_DAYS)

По умолчанию (без указания задач) выполняются: --user --system --snap --flatpak
EOF
}

add_task() { local t; for t in "$@"; do [[ " ${TASKS[*]-} " == *" $t "* ]] || TASKS+=("$t"); done; }

FORCE_LIST=0
while (($#)); do
  case "$1" in
    -n|--dry-run) DRY_RUN=1 ;;
    --apply)      DRY_RUN=0 ;;
    -y|--yes)     ASSUME_YES=1 ;;
    --list)       FORCE_LIST=1 ;;
    -h|--help)    usage; exit 0 ;;
    --user)       add_task "${USER_TASKS[@]}" ;;
    --system)     add_task "${SYSTEM_TASKS[@]}" ;;
    --snap)       add_task snap ;;
    --flatpak)    add_task flatpak ;;
    --journal-size=*) JOURNAL_MAX_SIZE="${1#*=}" ;;
    --tmp-days=*)     TMP_KEEP_DAYS="${1#*=}" ;;
    --docker-volumes) DOCKER_PRUNE_VOLUMES=1 ;;
    --docker)     add_task docker ;;
    --trash)      add_task trash ;;
    --thumbnails) add_task thumbnails ;;
    --fontcache)  add_task fontcache ;;
    --recent)     add_task recent ;;
    --baloo)      add_task baloo ;;
    --browsercache) add_task browsercache ;;
    --apt)        add_task apt ;;
    --kernels)    add_task kernels ;;
    --journal)    add_task journal ;;
    --tmp)        add_task tmp ;;
    -*)           err "неизвестный ключ: $1"; usage; exit 2 ;;
    *)            err "неизвестный аргумент: $1"; usage; exit 2 ;;
  esac
  shift
done

if (( FORCE_LIST )); then
  printf 'Задачи, выполняемые по умолчанию:\n'
  printf '  --user     %s\n' "${USER_TASKS[*]}"
  printf '  --system   %s\n' "${SYSTEM_TASKS[*]}"
  # snap и flatpak берём из EXTRA_TASKS, чтобы список не расходился с набором
  for t in "${EXTRA_TASKS[@]}"; do printf '  --%-8s %s\n' "$t" "$t"; done
  printf 'Только по явному выбору: %s\n' "${OPTIONAL_TASKS[*]}"
  exit 0
fi

[[ ${#TASKS[@]} -gt 0 ]] || add_task "${USER_TASKS[@]}" "${SYSTEM_TASKS[@]}" "${EXTRA_TASKS[@]}"

# ------------------------------------------------------------------ sudo
SUDO=()
needs_root=0
for t in "${TASKS[@]}"; do
  case "$t" in apt|kernels|journal|tmp|snap) needs_root=1 ;; esac
done
if (( needs_root )) && (( EUID != 0 )); then
  if have sudo; then
    SUDO=(sudo)
  elif (( DRY_RUN )); then
    warn "sudo недоступен — предпросмотр без повышения прав"
  else
    err "нужны права root, но sudo недоступен"; exit 1
  fi
fi

# ------------------------------------------------------------------ блокировка
# Два одновременных запуска (cron + руками) дерутся за apt/snap/flatpak-локи.
if have flock; then
  LOCK_FILE="${XDG_RUNTIME_DIR:-/tmp}/clean-kubuntu.$(id -u).lock"
  exec 9>"$LOCK_FILE"
  if ! flock -n 9; then
    warn "уже выполняется другой экземпляр (lock: $LOCK_FILE)"
    exit 0
  fi
fi

# ------------------------------------------------------------------ запуск
if (( DRY_RUN )); then
  log "РЕЖИМ ПРЕДПРОСМОТРА — ничего не будет удалено (используйте --apply)"
else
  log "РЕЖИМ УДАЛЕНИЯ"
fi
dim "задачи: ${TASKS[*]}"
echo

if (( ! DRY_RUN && ! ASSUME_YES )); then
  a=""
  # Без tty (cron/CI) read возвращает ошибку, и "$a" осталась бы неопределённой:
  # при set -u это обрывало бы скрипт вместо чистого отказа.
  [[ -t 0 ]] && read -r -p "Продолжить удаление? [y/N] " a
  [[ "$a" == [yYдД]* ]] || { warn "отменено"; exit 0; }
fi

rc=0
for t in "${TASKS[@]}"; do
  if declare -F "task_$t" >/dev/null; then
    "task_$t" || { warn "задача '$t' завершилась с ошибкой"; rc=1; }
    echo
  else
    warn "задача '$t' не найдена"
    rc=1
  fi
done

if (( rc == 0 )); then
  log "Готово."
else
  warn "Готово с ошибками — см. сообщения выше (код возврата 1)."
fi
(( DRY_RUN )) && dim "Это был предпросмотр. Запустите с --apply для реальной уборки."
exit "$rc"
