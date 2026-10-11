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
| A05 independent QA/TD/Council | Prospective controls, exact C2 QA и другой TD приняли A01–A05; final Council/CI/delivery отдельно |
| A06 public CI/delivery | Ожидается итоговый checked head/PR/source archive/preservation |

## Ход и границы

Feasibility подтверждён 02:58:25UTC, до03:32:21 gate. PM сохранил оба draft-прогона, затем усилил java/javac prebinding/per-invocation hashes/freshclass set и process metadata. Исполнение старого reference01 не выдаётся за проверку позднейшей версии runner. Root первое создание corpus/events остановилось на PowerShell синтаксисе inline here-string до исполнения; исправленная structured serialization выполнила freeze один раз. Первые широкие historical rg searches встретили ACL-denied и truncated output, не являются полным аудитом. Старый отсутствующий PM восстановлен новым отдельным агентом pm_s7; эмоциональный советник отдельный и без дополнительного голоса.

Полные private stdout/stderr/exit/source/class proofs находятся в SID-only `.local/sprint07`. Полное покрытие кандидата и реальные independent replay фиксируются отдельно. Пропущенные PostgreSQL tests не означают новый backup/restore proof. Ни один новый Windows пакет/релиз/установка не создаётся: приложение0.5 прежнее, библиотечный preview пока не подключён к UI/HTTP. DISK01 OPEN; native5.1 full backup UNVERIFIED; arbitrary upstreamXXE/full service/attributes/classifiers/calendars/DST/miner/BPMN quality не проверены.

Следующий прикладной шаг после принятия: отдельная защита пользовательского preview/подтверждаемого импорта в UI с сохранением исходного файла и audit trail. Операционная cleanup требует отдельной backup/newrestore/rollback цепочки.

## Независимая приёмка C2

C1 `9a396bca34a3b383f1af567282e16616cc01ddf4`, C2 `e890d84c95c892fa25f465e30ca215c803c49b71`. C2 усиливает comparator counters/action reasons/selfsource hash; библиотека и example идентичны C1. Независимый observer EXE SHA256 ED86C6FC5644A3B083094F8F1EEBFB2E81EBC301E28C37EB2696F04DC5789086 построен из свежего Git archive C1, все478source blobs проверены. Текущий JDK504file inventory подтверждён до final reference02; первый исследовательский QA reference до полной JDK проверки не выдаётся за этот proof.

[QA C2](../flw/evidence/sprint-07-qa-c2-position.md), JSON SHA256 C0643F1CF1B88643459AC9ED6E5412ADD1D40020DAECC50370447475B930CE5B; [TD](../flw/evidence/sprint-07-td-final.md), SHA256 2E36A8DC78202F45D53C59DB9AA9BDAAEE09CEE01786D40FAC0A2BBA74FF00EF. Область A01–A05 принята, A06 final head CI/Совет/публичная доставка ещё ожидается. Ручное независимое XML-derived сравнение проверяет все11inputs; подделанные counters и default reasons отвергнуты exit1 без report. Synthetic Python JSON response в reason probe не является новым XES execution.

[Reference observations](../fixtures/oracle-service/reference-results.json), SHA256 CE686375AAD6F92B458D556ADD466C768F272E218DEA2274CF5F45CD95313065; [Rust comparison](../fixtures/oracle-service/rust-comparison.json), SHA256 9A9D78E55329F8A53BA6ABC3527DB057EAFA03B7D852256205592C8BA1461CB8. Оба exports независимо byte/semantic checked по whitelist; original raw fingerprints сохранены, абсолютные private paths/source/classes/credentials не публикуются. Comparator source SHA256351FE43BABE9B65E5D6D1640C4C36FCE241325B855AC3B5CFE096E5DD4E6C9C1 записан в результате.

Аудит449selectedlog/JSON artifacts,922549байт/unreadable0 на snapshot включает result/proof/synthetic JSON и не означает449rawprocessstreams. Начальные tool-only/truncated reads и исправленный QA boolean-type диагностический guard отражены отдельно. Контроль кандидатуры пропорционален риску ложной совместимости; два freeze оправданы конкретным verifier gap, а не каждой черновой правкой. Повтор одной доказанной причины не установлен; новый skill не создаётся.
