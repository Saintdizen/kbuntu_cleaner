# kbuntu_cleaner

Скрипт уборки мусора для Kubuntu / Ubuntu + KDE Plasma.

Главный принцип: **по умолчанию ничего не удаляется**. Сначала вы видите план
(dry-run), и только с ключом `--apply` скрипт реально чистит систему.

## Быстрый старт

```bash
chmod +x clean-kubuntu.sh

./clean-kubuntu.sh            # предпросмотр: что будет удалено (безопасно)
./clean-kubuntu.sh --apply    # выполнить уборку (спросит подтверждение)
```

## Что чистится

| Группа           | Задача         | Что делает                                              | Права |
|------------------|----------------|---------------------------------------------------------|-------|
| `--user`         | `trash`        | Корзина (`~/.local/share/Trash`)                        | нет   |
| `--user`         | `thumbnails`   | Кеш миниатюр `~/.cache/thumbnails`                      | нет   |
| `--user`         | `fontcache`    | Кеш шрифтов + `fc-cache -f`, перезапуск plasmashell     | нет   |
| `--user`         | `recent`       | Список недавних документов                              | нет   |
| `--system`       | `apt`          | `autoremove --purge`, `clean`, удаление конфигов `rc`    | sudo  |
| `--system`       | `kernels`      | Старые ядра (кроме текущего и самого нового)            | sudo  |
| `--system`       | `journal`      | Журнал systemd, оставляется ≤ 200M                      | sudo  |
| `--system`       | `tmp`          | `/tmp` и `/var/tmp` старше 7 дней                       | sudo  |
| `--snap`         | `snap`         | Отключённые (disabled) ревизии snap                     | sudo  |
| `--flatpak`      | `flatpak`      | Неиспользуемые runtime (`uninstall --unused`)           | нет   |
| `--docker`       | `docker`       | `docker system prune -af --volumes`                     | нет\* |
| `--baloo`        | `baloo`        | Индекс поиска KDE (переиндексируется сам)               | нет   |
| `--browsercache` | `browsercache` | Кеши Firefox/Chrome/Chromium/Brave/Opera/Vivaldi/Yandex | нет   |

\* Docker берётся от текущего пользователя; если нужен root — запустите скрипт от root.

По умолчанию (без указания задач) выполняются `--user`, `--system`, `--snap`,
`--flatpak`. Тяжёлые задачи (`--docker`, `--baloo`, `--browsercache`) в группы не
входят и включаются только явным флагом.

## Примеры

```bash
# Только предпросмотр системной уборки
./clean-kubuntu.sh --system

# Реально почистить и не задавать вопросов (для cron)
./clean-kubuntu.sh --apply --yes --user --system

# Освободить место в Docker
./clean-kubuntu.sh --apply --docker

# Список всех доступных задач
./clean-kubuntu.sh --list
```

## Параметры

| Ключ          | Описание                                       |
|---------------|------------------------------------------------|
| `-n`, `--dry-run` | Предпросмотр (режим по умолчанию)          |
| `--apply`     | Реальное удаление                              |
| `-y`, `--yes` | Не спрашивать подтверждения                    |
| `--list`      | Показать доступные задачи                      |
| `-h`, `--help`| Справка                                        |

## Автозапуск по расписанию

Раз в неделю (пользовательская уборка, systemd-таймер):

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/clean-kubuntu.service <<'EOF'
[Unit]
Description=Clean Kubuntu junk

[Service]
Type=oneshot
ExecStart=%h/PROJECTS/ubuntu_clean/clean-kubuntu.sh --apply --yes --user
EOF

cat > ~/.config/systemd/user/clean-kubuntu.timer <<'EOF'
[Unit]
Description=Weekly clean

[Timer]
OnCalendar=weekly
Persistent=true

[Install]
WantedBy=timers.target
EOF

systemctl --user daemon-reload
systemctl --user enable --now clean-kubuntu.timer
```

## Замечания по безопасности

- Скрипт **не** трогает личные файлы вне кешей/корзины.
- Старые ядра удаляются через `apt purge`, поэтому их не останется в загрузчике.
  Убедитесь, что текущее ядро (`uname -r`) работоспособно, прежде чем чистить.
- `--baloo` и `--docker` могут потребовать времени на повторную индексацию/загрузку.
- Кеш шрифтов чистится по известной проблеме (падения plasmashell из-за
  повреждённого `~/.cache/fontconfig`); после очистки выполняется `fc-cache -f`
  и перезапуск `plasma-plasmashell.service`.
