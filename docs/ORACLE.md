# Конкретное сравнение с Apromore

Текущий следующий уровень проверен в Sprint06: настоящий **OpenXES XesXmlParser → LogParser.getSimpleLog(XLog,XEventNameClassifier)** на десяти новых и шести прежних XES. [Контракт, расхождения и воспроизведение](XES_ORACLE.md), [отчёт06](SPRINT_06_REPORT.md). Новая проверка не использует внешний текстовый адаптер. Portal/service validateLog, timestamp normalization legacy и miner/calendar остаются отдельными непроверенными контрактами.

## Исторический reference спринта03

Область этого oracle — **ApromoreCore, SplitMiner LogParser.getSimpleLog(String)**, неизменённые `LogParser.java` и `SimpleLog.java` из commit `bbf24dfd43e72d6992392465f875a4367cbe792b`. Это настоящий выбранный компонент, а не запуск Portal или всего SplitMiner. Фактический запуск и результаты подтверждаются только отдельным evidence; наличие harness само по себе не означает PASS.

Шесть исходных синтетических XES и их SHA256 закреплены в [corpus.json](../fixtures/oracle/corpus.json). Эталоны — явно записанная ручная арифметика PM; независимый QA проверяет её отдельно. Примеры: выбор AB/AC, повтор AA, пустая трасса, Unicode с переводом строки и обратным порядком, lifecycle start/complete как отдельные события, обратное время с равными timestamps. Все названия трасс одинаковы намеренно; они не объединяются. Основное сравнение использует исходный порядок, classifier concept:name, каждое lifecycle-событие отдельно. Для шестого примера также записан ручной timestamp-эталон AC B со стабильным исходным порядком при равном времени; его присутствие не означает фактический запуск legacy timestamp normalization.

Для настоящего текстового overload необходим явно внешний адаптер: последовательности XES переводятся в строки `frequency::label::label`. Labels представлены обратимым hex UTF-8 токеном с префиксом L, чтобы грамматика legacy не разделяла двоеточия/переводы строк. Сохранены оба SHA: исходного XES и нормализованного текста. Legacy получает уже нормализованные последовательности; поэтому **совместимость импортёров XES, их defaults и timestamp sorting не проверена**. Ручной XES→text adapter сам проверяется независимым QA. Текстовая частота каждого исходного trace равна 1; объединение одинаковых последовательностей делает именно реальный LogParser.

## Фактически полученный узкий эталон

2026-10-10 выполнены build-01/reference-03 (actual version/archive provenance), ранний reference-02 уже был проверен до 11:49:59 UTC: шесть реальных Java запусков, каждый exit 0. Download attempt 01 завершился через 180 секунд timeout с частичным ZIP; attempt 02 возобновил оставшиеся байты, полный SHA256 совпал с официальными metadata. Обе попытки и предыдущий exploratory reference-01 сохранены отдельно. Компиляция reference имеет upstream unchecked warnings, ошибок нет. Обработка unused XLog overload не выполнялась.

Фактический безопасный output: [reference-results.json](../fixtures/oracle/reference-results.json), SHA256 `5A7D3269647AED5DED752FB495A572770BC81A600321A6AAF374DD4F3CAD8D0A`. Corpus SHA256 `6C0ADE912A2C6E9DB989ECD0C81E2B4C5FE3C39D2FA6544837497976F5A6FC5B`. Source hashes и compiled-class hashes находятся в output; дополнительно байты каждого source совпали с Git blob SHA закреплённого tree.

| Пример | Legacy cases | Legacy activities | Legacy variants | Rust events против ручного эталона |
|---|---:|---:|---:|---:|
| alternatives | 3 | 3 | 2 | 6 |
| self-loop | 2 | 1 | 2 | 3 |
| empty-trace | 2 | 1 | 2 | 1 |
| unicode | 2 | 2 | 2 | 4 |
| lifecycle | 1 | 2 | 1 | 3 |
| timestamp-order, source | 1 | 3 | 1 | 3 |

Все узкие legacy counts/variants совпали с ручными эталонами. Предварительный настоящий Rust replay на **прежнем принятом 0.2 EXE** `E2189EA8C463E7E3E146EF7983608A95F474B2FFA35FA02555F8A0CF3E47986E` дал совпадение всех шести counts/variants/DFG с ручными эталонами и выбранных legacy полей. Его private report `.local/sprint03/oracle/rust-baseline-03/comparison.json` SHA256 `C0EE4B073489B8DBB1B150F28F59538A625670DB69FC1CA78B956128A98AB0B8`; own PID 3928/port 51980 завершён comparator. Это доказательство работы harness и baseline, **не приёмка нового Sprint03 runtime**. Новый frozen EXE должен быть независимо повторён QA. Публичная таблица не даёт legacy credit событиям/DFG.

Проверяемые legacy значения: cases, distinct activities, последовательности вариантов и их частоты после обратного декодирования labels. `SimpleLog.getTotalEvents()` у настоящего текстового overload остаётся -1; это сохраняется как фактический результат и не заменяется выдуманным count. Число событий, частоты действий и DFG проверяются Rust против ручной арифметики, **не против legacy DFG**. Внутренние numeric IDs не сравниваются. Все разницы сохраняются по полям; общий percentage parity не рассчитывается. Качество discovery, частотные процентные фильтры и BPMN не входят в это сравнение.

## Воспроизведение

Для developer oracle нужны Node.js и локальный JDK 11; в пользовательский Windows runtime они не входят. Системный PATH не меняется. Исходники reference скачиваются только в частный `.local/sprint03/oracle` по закреплённому commit:

- `Apromore-Custom-Plugins/SplitMiner-Logic/src/main/java/org/apromore/splitminer/log/LogParser.java`
- `Apromore-Custom-Plugins/SplitMiner-Logic/src/main/java/org/apromore/splitminer/log/SimpleLog.java`
- корневой `LICENSE` (дополнительно licence header каждого класса: LGPL-3.0-or-later).

В MIT runtime чужой LGPL-код не включается. Публичные harness/fixtures написаны отдельно, reference source/classes остаются private; provenance содержит URL/commit/hash/license. Хеш скачанного Temurin ZIP проверяется по официальным metadata до извлечения; версия `java -version` записывается. Отдельная подстановка compile-only OpenXES signatures необходима только для компиляции **неиспользуемого** XLog overload. Эти типы не импортёр и не OpenXES runtime, их методы выбрасывают исключение; harness вызывает только String overload. Запуск XLog overload такой сборкой запрещён и не заявляется. Java reference classes не изменяются.

```powershell
& tools/oracle/build-reference.ps1 -JdkHome '<absolute-local-jdk11>'
node tools/oracle/run-reference.mjs '<absolute-local-jdk11>' .local/sprint03/oracle reference-unique
node tools/oracle/compare-rust.mjs '<absolute-candidate-exe>' .local/sprint03/oracle/reference-unique/results.json .local/sprint03/oracle/rust-unique
```

Comparator сам создаёт новый ephemeral Rust процесс на свободном отдельном порту и завершает только свой процесс. Существующие 3000/3010 и PostgreSQL не используются. Отдельно записываются EXE hash, PID/port, raw stdout/stderr, каждый импорт/export и сравнение. Режим без PostgreSQL проверяет mining/import и не доказывает migration/durability. Новый executable требует нового запуска; старые результаты на новый кандидат не переносятся.

Нельзя перезаписывать каталог attempt: каждая попытка имеет отдельное имя. `freeze-corpus.mjs` воспроизводит байты из фиксированных literals; после фиксации любые изменения corpus требуют новых hashes и повторного независимого review. Не запускать generation между reference и Rust сравнением. Если реальный reference не запущен за 45 минут после принятия плана, A02 остаётся BLOCKED/UNVERIFIED; ручной corpus продолжает существовать отдельно и не выдаётся за Apromore.
