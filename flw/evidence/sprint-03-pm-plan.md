# Sprint 03 — независимая позиция PM

Существующее место /root/pm_final; отдельный голос от Customer. Прочитаны Customer, QA, TD плановые позиции и точный S3-P1. Разработка и исполнение проверок ещё не подтверждаются этой записью. Восемь часов: 11:37:57–19:37:57 UTC; последний резерв с 18:07:57 UTC защищён. Рабочие 3000/3010 и PG5435 не затрагиваются.

## Позиция до голосования

Приоритет пользователя имеет три последовательных результата: конкретное сравнение с настоящим Apromore, безопасная эксплуатация PostgreSQL, затем расширение редактора BPMN. Самостоятельный ручной corpus полезен для проверки Rust, но не заменяет первое требование. Допустим настоящий узкий компонент закреплённого ApromoreCore с явным названием и ограничениями. Полный продукт и совместимость всех алгоритмов этим не доказываются.

Рекомендую ранний 45-минутный предел запуска oracle, параллельно с проектированием хранения. Если запуск заблокирован, сохранить воспроизводимый диагноз, реальные затраты и status BLOCKED/UNVERIFIED A02; не объявлять весь спринт полностью завершённым. Независимый corpus A01 остаётся отдельным проверяемым результатом. Сравнение должно фиксировать исходные байты, версии, порядок событий, lifecycle и normalization; каждая разница сохраняется отдельно, без усреднения.

Одна аддитивная schema v1 без преобразования существующих документов достижима и снижает риск. Lease обязан предшествовать любому DDL; version/checksum и изменение структуры атомарны. Признание старого формата требует проверки структуры и документов, а не одного CREATE IF NOT EXISTS. Полный DB backup и реальный restore в отдельную БД предшествуют upgrade копии. Project JSON исключает auth и не является этим backup. Downgrade не обещается; возврат только через сохранённую исходную БД.

Операционные A03–09 имеют жёсткий приоритет. Таймаут ожидания ответа не равен отмене SQL или rollback; неопределённый commit требует failclosed и явного reopen без автоматического повторения mutation. До и после fault проверяется durable state. Bootstrap staging должен сохранять связку существующего кластера и секретов; неизвестное состояние отклоняется без удаления/новых паролей. Recovery jobs атомарно по проекту и идемпотентно; общая атомарность всех проектов не заявляется.

Зависимости и владельцы: Root storage/migration/deadlines/bootstrap/backup и шесть inputs; PM отдельный legacy harness/manifest/output comparator; QA независимо actual PG/crash/browser/package; TD независимо механизм и границы гарантий; Customer пользовательские сценарии. PM не принимает собственный oracle как независимый QA. BPMN task/flow add/remove следует только после operational gates; если времени недостаточно, A10 PARTIAL, без ослабления остальных требований. После рубежа final90min новых функций нет. Складывать параллельные оценки как последовательные нельзя; критический путь Root implementation → QA faults → exact frozen delivery имеет приоритет над editor scope.

A01/A11/A12 также необходимы для проверяемой поставки: корпус, регрессии и точная идентичность свежего пакета. Состояния A02 BLOCKED или A10 PARTIAL допускают честную частичную поставку, не полный успех цели. Любая потеря данных/прав, mixed migration или false success — STOP affected release независимо от большинства. Не изменять AC на финальной приёмке.

## Настоящий плановый голос S3-P1

Прочитан полный docs/SPRINT_03_PLAN.md и независимо пересчитан raw SHA256: **A33E3CE16F8E585AB288162BBCD684A054D183FF4B1F52266CE41A218746FB7F**.

Голос PM: **ЗА** принятие именно этого плана. Это разрешение ограниченной разработки, не product PASS и не release vote. Основание: план сохраняет mandatory operational safety, отдельно обозначает недостигнутый настоящий oracle и deferred BPMN как частичность, защищает существующие установки и финальную независимую проверку. Runtime, данные и остальные документы этой позицией не изменены.

## Настоящий targeted-resume голос S3-RESUME-1

Полностью прочитан flw/evidence/sprint-03-bootstrap-resume-proposal.md; raw SHA256 независимо пересчитан **2EEE2A43D569CEF06CC1F9823B66D4DB3D89D48E3183AB042B91BA634974C8DD**. Прочитаны actual QA bootstrap-repaired-resume01.json/bootstrap02-report.json, проверен текущий setup SHA256 **BD28F3B941101B5607B6A1BBC7D44D023EB2F0AE29702D4E7D9C2B7C34022003**.

PM **ЗА** именно targeted STOP resume по этой резолюции. Основания: same preserved cluster5557 native exit0, unchanged staged credentials/full original config backup; independently fresh5558 staged fault observed, resume0/same credentials, unknown config exit1/owned cluster preserved. Исправление explicit private File.Replace backup path сохраняет атомарную замену и диагностическую копию; не удаляет и не переинициализирует кластер. Shared-runtime junction QA test не приравнивается к fresh final package.

Голос не заменяет обязательную независимую TD closure и не возобновляет затронутую область до неё, даже если арифметическое большинство уже есть. Резолюция разрешает продолжить проверку bootstrap и affected development; optional BPMN — только после остальных operational gates. Final source/package/cold install/release остаются отдельно непроверенными. История фактического nativePS5 failure сохраняется; lost-secret recovery не обещается. Runtime/данные PM не изменял.

## Настоящий targeted-resume голос S3-RESUME-2

Полностью прочитан sprint-03-jobs-resume-proposal.md, raw SHA256 независимо пересчитан **A0978E7E68EB4D023501D8D82715B427830358952AB0E70482E8A2DB6A74A728**. Текущие jobs.rs F18E26F10C7B9EAA3D4F01D8E4B7B9E18D4C8FBC344A60EA9B36E34429191D36 и web.rs 0F07BE12B914F98D41FF564DEDBE1B56D04F738BA1C98DC14398AFFE5B9CD4B1 соответствуют proposal. Полностью прочитаны actual QA jobs03-04-release/report.json (SHA256 0E8788133108C551C1038810CD50460D45AAAA6948EC77C62A9390D5E67B9078) и startup-timings.json: 9792/13683/11278 ms. Все восемь recorded checks true. PM отдельно уже исполнил narrow oracle на exact1158AD54... release EXE; тот ephemeral replay не доказывает job/DB repairs.

PM **ЗА** именно S3-RESUME-2 targeted closure при обязательной независимой QA+TD closure, не финальную поставку. Согласен с commit-before-terminal-publication и failclosed callback refusal как необходимым восстановлением контракта, а не UI маскировкой. Same supported ~153MB release-mode reopen без reset/payload reduction честно отделён от debug failure и worst-case масштабируемости. Startup13.683s близок к15s caller envelope, поэтому high scaling/validation debt остаётся существенным следующим operational приоритетом; не обещать общую скорость/максимальную ёмкость на основании этого примера.

Граница прочитанного исполнения: финальная pre-crash запись report.json содержит Completed и Queued, pre-cancel Queued; сам этот report не доказывает kill точно в Running. Полные raw snapshots/предыдущие attempts и final QA должны отдельно подтвердить любое более широкое running-phase утверждение. Это не препятствует targeted closure фактически воспроизведённого queued terminal persistence дефекта, но не даёт PM нового running-crash PASS. Migration kill/connection faults и остальные A03–09 остаются mandatory; optional BPMN только после preliminary operational gates. Приёмка frozen source/EXE/ZIP, fresh nativePS5/package и Councilrelease отдельно впереди; старые resume votes не переносятся. Runtime и чужую evidence PM не изменял.

## Новый настоящий голос S3-RESUME-2b

Полностью прочитан отдельный immutable sprint-03-jobs-resume-proposal-v2.md; raw SHA256 независимо пересчитан **961E2B99F050B775D54047E8DD31A075B4BACEFC114DE6A93DA427CBA58D5D94**. Старый v1/голос выше исторические, не применяются и не переносятся.

PM **ЗА** именно S3-RESUME-2b. Фактическая correction соответствует независимо прочитанному report: observed queued crash recovery; Running-at-kill остаётся явно отдельной обязательной actual regression. Остальной evidence/source identity прежний, новые исполнения не выдумываются. Причины targeted FOR сохраняются: repaired commit-before-terminal, actual release same-data reopen с18 unchanged objects, debug/scaling high debt явно открыт. Обязательные QA+TD closure и большинство нужны до возобновления; прочие operational/frozen package/finalrelease gates этим голосом не приняты. No runtime/data changes by PM.
