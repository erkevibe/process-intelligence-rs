# Настоящий XES reference

Sprint06 расширяет oracle до **OpenXES parser и SplitMiner LogParser XLog overload** закреплённого ApromoreCore `bbf24dfd43e72d6992392465f875a4367cbe792b`. Прежний String overload с внешним XES→text адаптером остаётся историческим результатом; новые результаты получают журнал прямо из XML.

Путь: `new XesXmlParser(new XFactoryNaiveImpl()).parse(InputStream)` → `LogParser.getSimpleLog(XLog, new XEventNameClassifier())`. Исходники upstream неизменённые, реальные классы, без compile-only заглушек. Factory/classifier заданы явно; это не обещание всех defaults Apromore. Parser сохраняет XML-порядок, adapter не сортирует и не фильтрует события. `java.util.Date` наблюдается в миллисекундах; Rust сохраняет свою точность. Java запускается с UTC и UTF-8.

Последующий `EventLogServiceImpl.validateLog` не выполняется: он может задавать lifecycle=complete и удалять события без времени/имени, неподдерживаемые lifecycle и пустые трассы. Поэтому parser/consumer сравнение не равнозначно сервисному импорту, Portal, календарям/DST или качеству miner/BPMN. Reference предназначен только для фиксированного доверенного корпуса; безопасность arbitrary XES/XXE в upstream parser не проверена. Rust-only отрицательная проверка DTD отдельно подтверждает собственный запрет.

## Воспроизведение в Windows

Нужны Node и закреплённый Temurin JDK11.0.32.1+1. JDK source/archive SHA находится в `tools/oracle/reference.lock.json`. Системные настройки Java/PATH не меняются. Настоящие upstream исходники, jars, classes и raw logs остаются в закрытой `.local` и не входят в MIT runtime/package.

```powershell
& tools/oracle/build-xes-reference.ps1 -JdkHome '<JDK11 absolute path>' -NodePath '<node.exe absolute path>' -Attempt build-local01
& '<node.exe>' tools/oracle/run-xes-reference.mjs '<JDK11>' '.local/sprint06/reference/build-local01' 'fixtures/oracle-xes' '.local/sprint06/xes-local01'
& tools/cargo.ps1 -CargoArgs @('build','--locked','--example','oracle_xes')
& '<node.exe>' tools/oracle/compare-xes-rust.mjs 'target/debug/examples/oracle_xes.exe' 'fixtures/oracle-xes' '.local/sprint06/xes-local01/results.json' '.local/sprint06/rust-local01'
& '<node.exe>' tests/oracle_xes_tools.mjs
```

Папки попыток должны быть новыми: инструменты отказываются перезаписывать доказательства. Public lock содержит URL, размер, SHA256 и Git blob закреплённых исходников, jars/POM и источники лицензий; helper сам получает primary commit/tree manifest и проверяет bytes. Run повторно проверяет весь manifest и полноту executable classes/jars, actual Java version и hashes java/javac. JDK distribution integrity закрепляется отдельно архивом; версия/два executable hashes не заменяют full JDK distribution verification.

Десять новых XML и ручные ожидания закреплены до исполнения в `fixtures/oracle-xes/corpus.json`; SHA256 `8ebdb55f3a6a8c585865014c206d92be3d11e314925c52c1e7c6665ed9d14ac4`. Не регенерируйте корпус между reference и Rust. `freeze-xes-corpus.mjs` нужен для отдельной новой папки и отказывается изменять существующую. Каждый результат содержит исходный SHA, параметры, фактический exit и hashes stdout/stderr; ошибки upstream сохраняются.

Шесть прежних XES можно проверить тем же настоящим reference:

```powershell
& '<node.exe>' tools/oracle/run-xes-reference.mjs '<JDK11>' '.local/sprint06/reference/build-local01' 'fixtures/oracle' '.local/sprint06/six-local01'
& '<node.exe>' tools/oracle/compare-xes-regressions.mjs '<accepted0.5 EXE>' '.local/sprint06/six-local01/results.json' '.local/sprint06/six-rust-local01'
```

Регрессия запускает собственный ephemeral процесс на новом свободном порту, прекращает только его и не обращается к прежним установкам/БД. Проекция в старый comparator использует фактические XLog consumer counts/variants; старые manual DFG expectations отдельно проверяются и не получают legacy DFG credit. Поле `excluded` прежнего comparator историческое: authoritative scope новых доказательств — `actual-consumer-projection.json` и настоящий reference report.

## Зафиксированные различия

| Пример | Настоящий parser/consumer | Rust контракт |
|---|---|---|
| reverse-ties | XML B,A,C | source B,A,C; explicit timestamp A,C,B, стабильный tie |
| offset-equal | Два эквивалентных UTC момента | Те же UTC моменты и исходный порядок tie |
| lifecycle | start/complete — два отдельных события A | То же, без объединения интервалов |
| missing-time | Событие без времени сохраняется | source допускает; timestamp mode `missing_timestamp` |
| invalid-time | Исключение `java.util.EmptyStackException`, exit1 | Контролируемый `invalid_timestamp` |
| wrong-time-type | Строковый timestamp принят, typed timestamp отсутствует; raw type/value сохранены | `invalid_timestamp` |
| duplicate-name | Последнее имя B заменяет A | `duplicate_key` |
| submillisecond | `.123` миллисекунды | `.123456` сохраняется |

Это наблюдаемые различия контрактов, не основание автоматически ослаблять Rust validation. У каждого поля собственный результат; общего процента parity нет. Пустая трасса и Unicode отдельно включены. Ручной PASS означает выполнение выбранного Rust контракта; consumer consistency проверяет counts/variants против реального parser. Он не означает полную совместимость. Отчёт спринта связывает эти результаты с независимым QA и точными source/proof SHA.
