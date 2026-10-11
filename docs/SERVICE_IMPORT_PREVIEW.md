# Предварительный просмотр правил импорта

Спринт07 добавляет отдельный библиотечный API `service_preview::preview_xes` и developer example. Обычный импорт приложения остаётся строгим. Preview не сохраняет журнал, не запускает mining и не меняет пользовательские проекты. Выполнить после сборки: `cargo run --locked --example service_preview -- fixtures/oracle-service/mixed.xes`.

## Конкретный пример

В `mixed.xes` исходная трасса0 содержит пять событий; трасса1 пуста.

| Исходное событие | Действие | Результат |
|---|---|---|
| 0: A, время есть, lifecycle отсутствует | Дополнить lifecycle | A/complete остаётся с ordinal0 |
| 1: имя отсутствует, время есть | Дополнить lifecycle; удалить | Причина missing_activity, ordinal1 сохранён в change |
| 2: B, время отсутствует | Дополнить lifecycle; удалить | Причина missing_timestamp |
| 3: C/suspend, время есть | Удалить | Причина unsupported_lifecycle |
| 4: D/START, время есть | Сохранить | D/START остаётся с ordinal4 |
| Трасса1 пуста | Удалить трассу | Причина empty_case |

Добавленный `complete` — действие нормализации, а не исходный наблюдённый атрибут. Удаления перечисляют все применимые причины. Полностью отфильтрованный результат возвращает `fully_filtered=true` и пустой список cases; пригодность такого журнала для анализа не утверждается. `Case.id` содержит исходный номер трассы; ordinal события не перенумеровывается. Порядок XML сохраняется, timestamp sorting не выполняется. `start` и `complete` допускаются без учёта ASCII-регистра, пробелы не обрезаются.

## Доказательная граница

Upstream закреплён на ApromoreCore `bbf24dfd43e72d6992392465f875a4367cbe792b`, source Git blob `f0b3b2687763aa05db888cfaa65a6b24ee312a5b`. [Исходный файл](https://github.com/apromore/ApromoreCore/blob/bbf24dfd43e72d6992392465f875a4367cbe792b/Apromore-Core-Components/Apromore-Manager/src/main/java/org/apromore/service/impl/EventLogServiceImpl.java) скачивается по immutable commit. Reference проверяет весь SHA256/blob/size и уникальные границы; извлекает точные 1167 байт двух методов с offset9172 и SHA256 `c6180bdb3a5c1f58e781350ed063ddf636759ca002923d6fadf9839c1409c75c`. Их тела и helper не переписываются. Нейтральная generated оболочка компилируется с настоящими OpenXES типами из проверенного Sprint06 build. Adapter только наблюдает до/после/второго вызова и связывает реальные объекты с исходными индексами.

**Это исполнение извлечённых методов, а не запуск оригинального класса или полного сервиса.** `importFromStream`, default log-name, parser fallback, Spring/DAO/auth/persistence, Portal и полномасштабный Manager здесь не выполняются. Upstream произвольный XML/XXE не проверен; reference использует только доверенный фиксированный corpus.

## Преднамеренные различия

Сам `validateLog` проверяет наличие ключей имени/времени, а не их тип. Rust сохраняет строгий admission: пустое/нестроковое имя, string вместо date, неверная дата, duplicate semantic keys, нестроковый lifecycle отклоняются целиком. В preview допускается только отсутствующее имя для объяснённого удаления. DTD, unsupported global/list/container и повреждённый XML остаются отказами. Все byte/case/event/activity limits проверяются **до фильтрации**. API `preview_xes_checked` позволяет задать лимиты и сигнал отмены. Точный тип lifecycle/прочие XES attributes не претендуют на полное сохранение — используется существующая узкая EventLog модель.

Идемпотентность reference подтверждается полным сравнением наблюдений после первого и второго вызова. Rust отдельно проверяет стабильность уже нормализованного входа без новых действий и повторяемость preview; это не доказательство полного XES round trip с сохранением всех атрибутов.

Reference использует `XesXmlParser` и `XFactoryNaiveImpl`, как в узком oracle06; он не воспроизводит выбор текущей factory сервисом. Invalid-date завершается исключением upstream parser **до вызова извлечённого validateLog**. Java `equalsIgnoreCase` и Rust ASCII-сравнение могут различаться вне ASCII lifecycle; такое покрытие не заявлено. Отмена проверяется до/после Rust4PM parse и между событиями; текущий вызов самого parser не прерывается посередине. Runner ограничивает путь вывода приватной областью, но защищённые ACL каталога должен установить оператор до запуска.

Reference adapter вычисляет список действий по исходным атрибутам и сохранившимся объектам. Отдельный снимок уже удалённых объектов после вызова не выводится; default lifecycle для них следует из исходного отсутствия атрибута и проверенного безусловного присваивания в точном теле метода.

## Воспроизведение

Сначала создать настоящий проверенный OpenXES build по [инструкции06](XES_ORACLE.md). Затем:

```text
node tools/oracle/service-reference.mjs JDK BASE_BUILD fixtures/oracle-service .local/sprint07/reference-fresh
cargo build --locked --example service_preview
node tools/oracle/compare-service.mjs OBSERVER_EXE .local/sprint07/reference-fresh/results.json fixtures/oracle-service .local/sprint07/comparison-fresh
node tests/service-oracle-tools.mjs
```

Выходные каталоги свежие и приватные, со строгими ACL. Источники/jars/generated upstream/raw logs не публикуются; corpus, собственные adapters и безопасные наблюдения доступны. Wrapper reference проверяет текущие executable inputs и class set; извлечение не даёт право заявлять полную service совместимость. Сценарии, результаты, SHA и независимая приёмка находятся в [отчёте07](SPRINT_07_REPORT.md).
