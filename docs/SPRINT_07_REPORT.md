# Sprint07 — предварительный просмотр service-import

Окно четыре часа: 2026-10-11 02:52:21–06:52:21 UTC. План S7-P1 принят пятью фактическими голосами. Зафиксированы 11 примеров до исполнения; corpus SHA256 `49af9fb9c981ba77a49190211a1da1fbe1d9f9c4a595fc616754a2813f607b89`.

Добавлен отдельный Rust preview API/example: объяснённые удаления и default lifecycle с исходными trace/event номерами, source order, явный полностью пустой результат. Строгий parser и обычные HTTP imports используют прежний путь. Preview допускает отсутствие имени для объяснённого удаления, сохраняя raw limits/type/duplicate/XML/DTD отказы. Пользовательские проекты не изменяются. [Контракт и конкретный пример](SERVICE_IMPORT_PREVIEW.md).

Reference механически извлекает точные два метода upstream и выполняет их на реальных OpenXES типах. Это не запуск оригинального service-класса, Portal, persistence или importFromStream. Первые два draft-прогона: 11 исполнений каждый, 10 успешных; invalid-date воспроизводит `java.util.EmptyStackException`. Ручное сравнение11PASS: пять поддержанных policy scenarios, шесть explicit admission/error divergences. Эти цифры не являются общей долей совместимости.

Invalid-date падает в настоящем OpenXES parser до вызова метода; остальные десять примеров достигают обоих вызовов extracted validateLog. Полная Unicode lifecycle-политика, выбор factory сервисом и прерывание Rust4PM parse посередине не подтверждены.

| Критерий | Состояние |
|---|---|
| A01 exact method bytes/real OpenXES | Exact C2 independent replay ACCEPT; source28508байт/blob, slice1167байт/offset9172, generated envelope и реальные OpenXES/JDK проверены |
| A02 fixed manual corpus | 11 literal inputs заморожены до запусков; full names/indices/cardinality/order/lifecycle/time/action comparisons draft PASS |
| A03 explicit preview | Независимо подтверждены API/example, changes/fully_filtered, source IDs и stability on normalized input/no mutation |
| A04 strict safety/regressions | Независимые74 ordinary PASS/13PGignored,7Node guard groups, old10×2 и six strict fixtures PASS; raw limits/cancel/negative checks подтверждены |
| A05 independent QA/TD/Council | Prospective controls, exact C2 QA и другой TD приняли A01–A05; Пять реальных финальных FOR, итоговый CI и независимый delivery PASS |
| A06 public CI/delivery | Точный H CI, пять FOR, PR7 merge и независимый immutable-source/protected delivery PASS |

## Ход и границы

Feasibility подтверждён 02:58:25UTC, до03:32:21 gate. PM сохранил оба draft-прогона, затем усилил java/javac prebinding/per-invocation hashes/freshclass set и process metadata. Исполнение старого reference01 не выдаётся за проверку позднейшей версии runner. Root первое создание corpus/events остановилось на PowerShell синтаксисе inline here-string до исполнения; исправленная structured serialization выполнила freeze один раз. Первые широкие historical rg searches встретили ACL-denied и truncated output, не являются полным аудитом. Старый отсутствующий PM восстановлен новым отдельным агентом pm_s7; эмоциональный советник отдельный и без дополнительного голоса.

Полные private stdout/stderr/exit/source/class proofs находятся в SID-only `.local/sprint07`. Полное покрытие кандидата и реальные independent replay фиксируются отдельно. Пропущенные PostgreSQL tests не означают новый backup/restore proof. Ни один новый Windows пакет/релиз/установка не создаётся: приложение0.5 прежнее, библиотечный preview пока не подключён к UI/HTTP. DISK01 OPEN; native5.1 full backup UNVERIFIED; arbitrary upstreamXXE/full service/attributes/classifiers/calendars/DST/miner/BPMN quality не проверены.

Следующий прикладной шаг после принятия: отдельная защита пользовательского preview/подтверждаемого импорта в UI с сохранением исходного файла и audit trail. Операционная cleanup требует отдельной backup/newrestore/rollback цепочки.

## Независимая приёмка C2

C1 `9a396bca34a3b383f1af567282e16616cc01ddf4`, C2 `e890d84c95c892fa25f465e30ca215c803c49b71`. C2 усиливает comparator counters/action reasons/selfsource hash; библиотека и example идентичны C1. Независимый observer EXE SHA256 ED86C6FC5644A3B083094F8F1EEBFB2E81EBC301E28C37EB2696F04DC5789086 построен из свежего Git archive C1, все478source blobs проверены. Текущий JDK504file inventory подтверждён до final reference02; первый исследовательский QA reference до полной JDK проверки не выдаётся за этот proof.

[QA C2](../flw/evidence/sprint-07-qa-c2-position.md), JSON SHA256 C0643F1CF1B88643459AC9ED6E5412ADD1D40020DAECC50370447475B930CE5B; [TD](../flw/evidence/sprint-07-td-final.md), SHA256 2E36A8DC78202F45D53C59DB9AA9BDAAEE09CEE01786D40FAC0A2BBA74FF00EF. Область A01–A05 принята; A06 final head CI/Совет/публичная доставка завершена отдельными неизменными доказательствами ниже. Ручное независимое XML-derived сравнение проверяет все11inputs; подделанные counters и default reasons отвергнуты exit1 без report. Synthetic Python JSON response в reason probe не является новым XES execution.

[Reference observations](../fixtures/oracle-service/reference-results.json), SHA256 CE686375AAD6F92B458D556ADD466C768F272E218DEA2274CF5F45CD95313065; [Rust comparison](../fixtures/oracle-service/rust-comparison.json), SHA256 9A9D78E55329F8A53BA6ABC3527DB057EAFA03B7D852256205592C8BA1461CB8. Оба exports независимо byte/semantic checked по whitelist; original raw fingerprints сохранены, абсолютные private paths/source/classes/credentials не публикуются. Comparator source SHA256351FE43BABE9B65E5D6D1640C4C36FCE241325B855AC3B5CFE096E5DD4E6C9C1 записан в результате.

Аудит449selectedlog/JSON artifacts,922549байт/unreadable0 на snapshot включает result/proof/synthetic JSON и не означает449rawprocessstreams. Начальные tool-only/truncated reads и исправленный QA boolean-type диагностический guard отражены отдельно. Контроль кандидатуры пропорционален риску ложной совместимости; два freeze оправданы конкретным verifier gap, а не каждой черновой правкой. Повтор одной доказанной причины не установлен; новый skill не создаётся.

## Публичная доставка и завершение

Техническая приёмка завершена 2026-10-11T03:25:41.665876+00:00, 33 минут после начала при лимите четыре часа. Это выбранный developer/API этап, не полный enterprise и не пользовательский UI. Итоговая человеческая приёмка отдельна.

[Совет S7-F1](../flw/evidence/sprint-07-council-final.json): пять фактических FOR по SHA256001E9FEED166D4CBF45BD3AF3870CE2C74A12CF9EEB373813E4E43CB633022F5. Draft26E7 с опечаткой исправлен до любого внешнего голоса; в принятии учитывается только001E. Root ownproposal не требует невозможного selfSHA внутри файла, но его полный файловый SHA/explicitFOR проверен. Каждый отдельный агент дал новый голос после чтения и хеша.

[Итоговый CI](../flw/evidence/sprint-07-qa-final-ci.md), JSON SHA256D503AAA9382A3E3ABC609A60FA27E486936FA19E59A7E030E5813BD2CF46A666: оба exactH прогона успешны, full28available files/327787B audited.74ordinary/13PGignored/Node5+7/fmt/clippy/release/ownhealth/upload; pushcheckoutHfb905527212c32e557562434502db3cf5a212d21 отдельно от syntheticPR1232a31917de37b8bc8225a90d2745265b26de9f. ActualJava локально, PG/newbackup не в этом run.

[PR7](https://github.com/erkevibe/process-intelligence-rs/pull/7) merged в `18ad5f18c1007cf96d4896d76e5ef87ebbf9f930` при сохранении headH/base3bec813ff0ee158ccef8c3e245330a6d15cf87da/remote guards. [Независимая доставка](../flw/evidence/sprint-07-qa-delivery.md): анонимный immutable M архив SHA2567A9A8AC23F369F4A8A2B6F363F9619631DDF2A07A5EE7E73D719FEF34A9FA255, все485file-set/Gitblob bytes/exclusions/projections/lineage проверены. Пять прежних ready установок и04/05ZIP сохранены read-only; это не новое доказательство всех DB contents. Нет login/config/DB/processmutation.

Подготовленные delivery helpers прошли syntax validation до исполнения; guardedmerge и анонимное скачивание/полный verifier прошли с первой попытки. Никакая прежняя ошибка не скрыта этим локальным успехом. Завершающий K меняет только документы/доказательства и соответствует проверенному H по исполняемым файлам. Windows0.5 продолжает работать; версия0.6/release/install не создавалась. Следующий stage — operator preview/подтверждаемый импорт с сохранённым исходником и audit trail; cleanup отдельна.

[Независимый TD после доставки](../flw/evidence/sprint-07-td-delivery.md): scoped ACCEPT, SHA256 DEB1BE6EC0756B90671CEE78DF994B149282D0A18F63BA76BDAD303504C5E365; остаточный долг и границы сохранены.
