# Локальная сеть: установка и ежедневные копии

Профиль: Ubuntu 24.04 x86-64, один экземпляр приложения 0.11.0, локальный
PostgreSQL 18, Caddy и сертификат частного центра сертификации. База и
приложение слушают только `127.0.0.1`; Caddy принимает HTTPS на адресе
сервера в локальной сети. Это отдельный вариант
[профиля Linux/TLS](LINUX_TLS_DEPLOYMENT.md).

Для этого размещения используются `deploy/linux/Caddyfile.lan` и
`deploy/linux/process-intelligence-proxy.service`. Unit ожидает закреплённый
бинарник Caddy в `/usr/local/bin/caddy` и файл
`/etc/process-intelligence/caddy-environment` с PI_TLS_HOST (LAN IPv4),
PI_TLS_CERT, PI_TLS_KEY и PI_BACKEND_PORT=3000. PI_PUBLIC_ORIGIN приложения
должен совпадать с `https://` и этим адресом. Не заменяйте этими файлами
конфигурацию уже работающих чужих сайтов.

## Доверие HTTPS

Сертификат сервера должен содержать точный IP в subjectAltName. Клиенты
проверяют его цепочку и адрес. Не отключайте проверку TLS ради открытия
страницы. На компьютерах пользователей устанавливается только публичный
сертификат частного CA; его ключ остаётся у оператора и не передаётся серверу.
Доверие следует ограничить теми компьютерами, которым нужен доступ.

В Windows оператор может импортировать публичный CA в хранилище текущего
пользователя; системное окно подтверждает сам пользователь:

```powershell
Import-Certificate -FilePath .\processmining-lan-ca.crt -CertStoreLocation Cert:\CurrentUser\Root
```

Не распространяйте `server.key`, ключ CA или файл подключения к базе.
Для проверки без изменения системного доверия:

```bash
curl --fail --cacert processmining-lan-ca.crt https://SERVER_LAN_IP/health
```

Частный CA не является публично доверенным сертификатом. На каждом новом
компьютере требуется собственная установка доверия. Выпущенный для первого
сервера сертификат действует до 25 октября 2027 года; автоматического
продления нет. Оператор должен выпустить замену заранее, проверить SAN,
срок, цепочку и соответствие ключу, затем выполнить контролируемый restart
прокси по [инструкции обслуживания](LINUX_SERVICE_OPERATIONS.md).

## Копии по расписанию

В `deploy/linux` находятся три файла:

- `process-intelligence-backup.py` — полный дамп базы, роли кластера,
  защищённая конфигурация, контрольные суммы и сохранение последних 14 копий.
- `process-intelligence-backup.service` — запуск и возврат приложения после
  ошибки или прерывания процесса копирования.
- `process-intelligence-backup.timer` — ежедневно в 03:00 Asia/Qyzylorda.

Скрипт рассчитан на конкретное размещение: база `process_intelligence`,
кластер `/etc/postgresql/18/main`, служба `process-intelligence.service`,
прокси `process-intelligence-proxy.service`, Caddy в `/etc/caddy`. Перед
использованием на другой установке сверить константы и перечень CONFIG_PATHS.
Он не является средством автоматического поиска и изменения чужих служб.

Установка оператором из проверенного исходного каталога:

```bash
install -o root -g root -m 0755 deploy/linux/process-intelligence-backup.py /usr/local/sbin/process-intelligence-backup
install -o root -g root -m 0644 deploy/linux/process-intelligence-backup.service /etc/systemd/system/
install -o root -g root -m 0644 deploy/linux/process-intelligence-backup.timer /etc/systemd/system/
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/process-intelligence-backup.service /etc/systemd/system/process-intelligence-backup.timer
systemctl start process-intelligence-backup.service
systemctl enable --now process-intelligence-backup.timer
systemctl list-timers process-intelligence-backup.timer
```

Копирование кратковременно останавливает приложение, поэтому активные
запросы и SSE могут прерваться. PostgreSQL продолжает работать; после дампа
служба запускается и проверяется `/health`. Если приложение было намеренно
остановлено до задания копирования, задание пропускается без его запуска.
Для обслуживания можно создать `/etc/process-intelligence/maintenance`,
затем остановить таймер. Не создавайте этот файл как способ скрыть ошибку
копирования; после обслуживания оператор удаляет собственный маркер и
возвращает таймер.

Каталог `/var/backups/process-intelligence` имеет права root:root 0700.
Каждая завершённая копия содержит `database.dump`, `cluster-roles.sql`,
`configuration.tar.gz` и `manifest.json`. Конфигурация содержит секреты;
не прикладывайте эти файлы к публичным отчётам. После отказа остаётся каталог
`.partial`, который не считается успешной копией и не участвует в ротации.
Оператор проверяет причину и свободное место; автоматическое удаление
неудачных попыток не настроено.

Проверка таблицы содержимого `pg_restore --list` не заменяет восстановления.
Нужна отдельная репетиция в новой базе: сравнить все таблицы, последовательности
и схему, запустить приложение с восстановленной базой и проверить прежние
отчёты. Первая целевая репетиция выполнена; см. [отчёт](SPRINT_34_REPORT.md).
Дамп ролей сохраняет роли всего локального кластера; не применяйте его поверх
чужого кластера без отдельного разбора.

Успешные копии на том же диске не защищают от потери сервера. Первую копию
проверенно скачали на компьютер оператора, но регулярная доставка за пределы
сервера требует выбранного хранилища и отдельной настройки. Публичные
контрольные суммы не удостоверяют автора копии.

Для диагностики:

```bash
systemctl status process-intelligence process-intelligence-proxy postgresql@18-main
systemctl show process-intelligence-backup -p Result -p ExecMainStatus
journalctl -u process-intelligence-backup --since yesterday
systemctl list-timers process-intelligence-backup.timer
df -h / /var/backups/process-intelligence
```

## Фактические ограничения приложения

Импорт XES ограничен 20 МиБ, 100 000 событиями и 20 000 случаями. Сохраняемое
построение BPMN ограничено шестью действиями, 64 трассами, 500 событиями и
32 вариантами; оценка тоже имеет собственные вычислительные пределы.
Более мощный VPS не повышает эти программные пределы. Измерения на
синтетических данных не являются оценкой нагрузки реальных процессов.
Для следующего изменения нужны реальные журналы и вопрос пилота из
[плана развития](DEVELOPMENT_PLAN.md).
