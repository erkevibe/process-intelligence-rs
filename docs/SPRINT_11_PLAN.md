# Sprint11: надёжные проверки, SQL5 и установка

Точное предложение после исходных позиций, до голосования. Восемь часов 12 октября 2026: 10:51–18:51 UTC, местное время 15:51–23:51 Asia/Qyzylorda. Runtime freeze 17:21 UTC оставляет 90 минут независимой приёмки. Ветка codex/sprint-11 от c3af6feed1f4f64664c910d883887da31294ef77.

## Цель и исходные условия

Сначала устранить повторные ошибки проверочных оболочек одним общим механизмом. Далее получить настоящий SQL5 на исходном запросе полного corpus. Проверить штатную новую установку, конкретные миграционные сбои и RBAC. Исходные R3-01/02/03/04, DISK01, SPRINT_09_SPECIFICATION.md и C01–C18/subcases/F01–F03 не сокращаются. Результат — фактический прогресс и конкретная принятая область, без гарантии полного R2–R5/enterprise.

Риск-аппетит: минимальный риск пользовательским данным. Черновики/парсеры/чтение — лёгкий рабочий цикл; destructive integrated candidate — независимые QA и TD, prospective ProcessLogAuditor и STOP. Автор не принимает собственные исправления. Один этап допускает обычные обратимые draft repairs без нового полного Совета на каждую строку.

## Ресурсы и границы

Root измерил C: около 86,7 GB свободно, NTFS/ACL проверяются перед фазой. Только новые каталоги .local/sprint11, новые имена pi_restore_s11_*, private config и собственные loopback app/PG/proxy порты (3095, 5462–5463, 5562–5563 при фактическом отсутствии). Ресурсный admission использует актуальное свободное место, полный консервативный расход фазы, не менее 3 GiB для новой распаковки и отдельный runtime-floor. Вычисление Int64 учитывает PostgreSQL и все копии/снимки; уменьшение корпусных данных ради места запрещено.

Начальный снимок прежних именованных портов: все отсутствуют до наших запусков; это текущий факт, не наша остановка и не непрерывное доказательство сохранности. Старые установки, PG/datadir/ACL/config/аккаунты/архивы/доказательства не менять, не логинить и не выполнять SQL. Финальная проверка ограничена исходным именованным снимком/артефактами. Никакого удаления старых файлов или неудачных новых данных ради места.

Два различающихся runtime: диагностический неизменный cleanup 0.7.1, source b4edef34b083d1cb7737cf648f1c051eeb94127a, EXE ожидается 7FC3812772D64D9A74EEC55413C41C6C189167FFEB279EFCE2613CA7FD6AD195 (проверить фактические bytes); install/lifecycle кандидат 0.7.2 source9005, EXE B14F3D2E306DBB8FF81EC37A8BF8A70F63E53252E43079364E1C09D4AF345DE6, ZIP EE1DD55968FEB636F5D7EA66DFB26B4F3DF83E236094A70EF3F254C322542A64. Его Apply остаётся исключённым. Диагностический успех не переносится автоматически на новый продукт. Возвращение cleanup требует отдельного конкретного интегрированного кандидата и всех затронутых gates.

## Фазы

| UTC | Работа | Переход |
|---|---|---|
| 10:51–11:35 | Ресурсный baseline, позиции/план; общий runner и регрессии причин | Windows argv/canonical datadir, SHA case, типизированная сумма, CreateNew, owned Job до GO, bounded output/drain/native exit; QA/TD независимо проверяют до дорогих фаз |
| 11:35–12:30 | SQL5 feasibility | Новый пустой owned backend Observe/hold исходного Parse/Bind/Execute без добавления SQL/Flush/flags/изменения options. Реальная 57014 именно statement_timeout и управляемый native отказ; иначе SQL5 остаётся OPEN |
| 12:30–15:00 | При GO — полный SQL5 и аварийный corpus | Полный historical0.3, actual current changes/10 retained keys, verified backup/new restore; неизменные 5/2/10 и полный managed/catalog/sequence PRE/POST. Полная приёмка только весь C01–C18/subcases/F01–F03 |
| До 16:45 | Штатная установка, миграционные сбои, RBAC | Новый extract, полный manifest/1742 bytes set, штатный starter/setup/account/login/import/export/restart; отдельные verification/recovery копии, точные migration guards и отказные whole-state проверки |
| 16:45–17:21 | Завершение допущенных случаев и freeze | Один конкретный source/EXE/package scope; новые рискованные возможности поздно не начинать |
| 17:21–18:51 | Независимая приёмка и передача | QA/TD реальные исходные clause verdict; Customer user flow; безопасный отчёт/индекс; новые настоящие final votes; exact-head CI/PR/receipt. Условия release/tag/merge/user install решаются отдельно по фактическим gates |

Если к 12:30 настоящий механизм SQL5 не доказан, прекращается instrument churn, безопасные задачи установки/миграций продолжаются. Два повторных отказа одной причины требуют ремонта механизма и регрессии до повторения. Успех маленькой диагностики не закрывает полный исторический SQL5. Extended-cycle hold отдельно от CPU-duration. Bind write callback не объявляется server receipt; фактическая фаза и backend/error связываются явно.

Stock install требует точный единственный -D аргумент PostgreSQL через Windows argv и canonical identity, captured до assert, actual retained Job membership и полные native streams. Ready без setup не PASS. Credentials/Auth/cookie/private URL/raw dumps не печатаются и не публикуются. Сохранённые failed outputs остаются неизменными.

Migration/RBAC: ожидаемый specific unsupported schema отказ заморожен до запуска; generic Auth denial его не заменяет. Controlled failure/rollback/resume/no-op, backup→NEW restore и owner/editor/viewer/foreign/restart проверяются на новых named fixtures. Untouched verified restore не запускать/логинить; recovery/app copy отдельно. Полнота сравнения ролей/ACL/каталога определяется явно и отсутствующая область не получает зачёт.

## Владельцы и пожелания Customer

Root — реализация общего runner, стенд, интеграция и исполнение. QA `/root/qa_process` — независимые expected states, source registry и prospective live audit. TD `/root/technical_debt` — второй независимый reviewer/STOP и долг. PM `/root/pm_s9` — исходный clause crosswalk и ответы Customer. Customer `/root/customer_s6` — usable install/recovery и понятность результата. Фиксированные пять голосов не расширяются автоматически.

S11-C01 runner, C02 SQL5, C03 whole corpus, C04 real stock setup, C05 migration/RBAC приняты как цели/проверки с gates выше. C06 ясность опасных операций сохраняется из текущего UI/guide и перепроверяется в затронутом сценарии; новых security-audit обязательств не добавляем. C07 честный clause verdict/90 минут/точные bindings обязателен. Это решения по пожеланиям, не объявление их исполнения.

Финальный отчёт различает PASS/FAILED/OPEN/NOT-IN-RUN и сохраняет source attribution прежних примеров. Старые голоса и наличие нового места не превращают непринятый 0.7.2, SQL5 или весь R3 в PASS. До фактического решения этот документ — предложение.
