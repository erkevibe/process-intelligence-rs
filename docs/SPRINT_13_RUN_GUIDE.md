# Sprint13 — статус и операторский контракт кандидата0.7.3

**Это документация неполностью принятого кандидата.0.7.3 не выпущен как готовая очистка.** Для результатов и обязательных OPEN пунктов см.[отчёт](SPRINT_13_REPORT.md). Ниже описан интерфейс проверенного частного кандидата, а не предложение запускать его в существующей пользовательской установке.

## Папки списка проектов

Они группируют проекты внутри одной рабочей области и отличаются от папок ресурсов внутри проекта. Перенос сохраняет проект, участников, права и содержимое. Владелец папки не получает доступ к её проектам. Переносит проект его Owner; он может вернуть доступный проект в корень списка. Архив папки не архивирует проекты. Удаление папки разрешено только когда она пуста.

Конечные API/role/CAS/privacy примеры проверены. Реальный browser/Datastar workflow, concurrent demotion/CAS и весь lifecycle/restart/full-backup/new-restore ещё не приняты на0.7.3.

## Отдельная offline-очистка

Автоматической очистки при запуске, HTTP endpoint и планировщика нет. Перед Preview нужны остановленные приложения source и verification, проверенный полный штатный backup с исходным manifest, отдельная **новая** verification-база и частные пути внутри`.local` именно этой установки. Preview не восстанавливает поверх source и не удаляет его строки. Неудачные targets и доказательства сохраняются.

Оператор использует совместимые версии программы, PostgreSQL и штатных backup/restore tools. Прежние пользовательские, historical и failed установки не становятся тестовыми targets. Не повышайте права, чтобы обойти отказ identity; строка URL не заменяет фактическую identity базы.

Схема вызовов для отдельно разрешённой новой тестовой установки:

```powershell
pwsh -NoProfile -File tools/cleanup-legacy.ps1 -Mode Preview `
  -Database <source> -TargetDatabase <NEW-pi_restore_name> `
  -BackupFile <absolute-private-archive> -PlanFile <new-absolute-private-plan>
```

Preview вызывает штатное восстановление в новый target и Verify. План связывает точные EXE/archive/manifest, реальные system_identifier/database_oid, схему, полные values/versions/markers/ledger/sequence и кандидаты удаления. Нельзя подставить другой архив, повторно использовать старый plan после изменения данных или логиниться приложением в verification-копию.

После ручной проверки плана отдельный Apply требует его точный SHA256 и новый receipt path:

```powershell
pwsh -NoProfile -File tools/cleanup-legacy.ps1 -Mode Apply `
  -Database <same-source> -TargetDatabase <same-verification> `
  -BackupFile <same-absolute-private-archive> -PlanFile <same-private-plan> `
  -ConfirmPlanSha256 <exact-sha256> -ReceiptFile <new-private-receipt>
```

Пароли не передаются аргументами и не включаются в публичные отчёты. Wrapper загружает private operator configuration, использует ограниченные ACL, временно устанавливает только необходимые переменные процесса и восстанавливает окружение в finally. Нативные flags:`--cleanup-storage-verify`/`--cleanup-storage-apply`; рабочий каталог должен быть корнем соответствующей установки. Случайный другой EXE или working directory не является совместимым запуском.

## Результат и код завершения0.7.3

| Exit | JSON outcome | Значение |
|---|---|---|
|0|`cleanup_verified`|План проверен; удаления ещё не было|
|0|`cleanup_committed`|COMMIT подтверждён, квитанция сохранена|
|0|`cleanup_empty`|Корректный пустой результат; заявлено0 database writes|
|1|`cleanup_refused`|Контролируемый отказ с отдельным code; не выдавать за успешное удаление|
|2|`cleanup_outcome_unconfirmed`|Клиент не подтвердил исход COMMIT; нет автоматического повтора|
|3|`cleanup_committed_receipt_failed`|COMMIT известен как успешный, запись квитанции не удалась; повторять удаление нельзя|

Это текущие коды0.7.3. Старые0.7.2/SPRINT_09 документы с другими кодами и выключенным CLI относятся к своим версиям и не являются текущей инструкцией.

При unconfirmed сохраните исходные output/plan/archive. Независимое полное read-only reconciliation должно установить PRE, POST либо неожиданное/недоступное состояние. F02 на стенде дал PRE; F03 дал POST при том же client outcome. Одно сообщение об ошибке не различает эти случаи. Не делайте blind retry и не дописывайте квитанцию с выдуманным подтверждением COMMIT. При неожиданном/недоступном состоянии остановитесь и сохраняйте доказательства.

Восстановление означает restore исходного полного архива в **ещё одну новую** runtime-базу, полное сравнение PRE и совместимый запуск приложения. Verification-копия остаётся неизменной и не служит runtime. Это не вставка legacy JSON обратно в активную normalized-базу. В спринте проверены startup, четыре входа и полные экспорты; полный recovery/write-role/restart контракт ещё OPEN.

Лимиты не повышены:10000 managed rows,512 UTF-8 bytes на key/identifier,4MiB plan/receipt, statement5s/lock2s/transaction10s. DELETE освобождает логические записи, но не гарантирует физическое стирание или уменьшение PostgreSQL-файлов. VACUUM FULL, удаление установок и автоматический повтор не входят в интерфейс.

## Диагностические сценарии

`tools/sprint13/` содержит стендовые исходники, не пользовательский service manager. Они требуют точных частных входов, source/hash/config/ACL/Job/port/deadline pins и независимых допусков. Истёкшие S13-профили не запускаются снова; старые/failed targets не переиспользуются. Комментарий SOURCE-ONLY в сохранённой редакции отражает время её написания: фактический статус определяется exact SHA и authored evidence, а не комментарием или наличием файла.

Все новые локальные runtime-проверки прекратились по границе19:44:42 UTC. Дальнейшая передача допускает только source/metadata/read-only validation/CI и публичный source readback, без новых локальных запусков приложения или PostgreSQL. Отдельный ephemeral smoke в облачном CI использует публичные синтетические данные и не даёт нового historical/recovery/runtime зачёта. Полные частные captures остаются локально, публичный индекс содержит их безопасные агрегаты и хеши.
