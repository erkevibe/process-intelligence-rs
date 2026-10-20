# Sprint15 — конечные проверки R3

Промежуточный отчёт на20 октября2026,12:15 UTC. Восьмичасовое окно10:14:24–18:14:24 UTC сохраняется; новые runtime прекращаются к16:44:24. [План](SPRINT_15_PLAN.md), [текущий статус](SPRINT_15_STATUS.md), [операторская инструкция](SPRINT_15_RUN_GUIDE.md).

## Проверяемый контракт и результаты

Кандидат0.7.3 остаётся неизменным: EXE `23563DFF8FE93F339AD7F12FD0783AC3E2C53B8D9368C00D772A8FBABBE5F292`, ZIP `E79866DA3E9348CFA3EA08542D1A9FB405A47D9F7C5AE15F56979A4559AE3A4C`, build core `3f0b3caa34b9b4beaf4422f78c2e31c0f97d3209`. Последующий Git HEAD содержит диагностику и документы; он не называется commit сборки EXE. Замороженная README внутри ZIP содержит сведения0.7.2; текущий guide явно объясняет версию и маршрут PowerShell7. Native PowerShell5.1 не заявлен.

| Условие | Фактическое доказательство и границы |
|---|---|
| Concurrent catalog CAS | QA/TD: два действительно пересекающихся HTTP-запроса одной ревизии, один303/commit и один409. Полный Auth/catalog/audit replay и остальные строки сохранены. Это не произвольная межпроцессная гонка. |
| Отзыв прав | Тот же вошедший Editor получил403 после Owner demotion без ложного commit/audit; после восстановления роли та же сессия снова пишет. Не заявляется Actor, перехваченный до middleware. |
| Старый0.6.1 | Настоящий старый EXE отказал до listener с кодом1/«Доступ запрещён.»; полные managed/catalog/ACL обеих новых баз сохранены. Общая несовместимость старого Auth decoder, не изолированная причинность каталога и не schema_unsupported. |
| lock2 | Реально отправленный исходный LOCK получил55P03/lock timeout; четыре полных PRE и каталоги сохранены, DELETE/receipt отсутствуют. Apply1/observer0/outer0/PG0 и EOF проверены QA/TD. Production SQL и5s/2s/10s не изменены. |
| Hostile persisted Auth/catalog/audit |12 отдельных новых DB, одна точная JSON-path mutation на каждую: strict unknown fields, missing links/owner, cycle, owner association и конкретные audit trust/syntax отказы.36 полных пар managed/catalog/ACL,149 native records/298 потоков и PG0. Это конечный набор, не все возможные повреждения или восстановление исходных параметров policy digest. |
| Браузер/Datastar/публичный Start |54 фактических шага, Owner/Viewer/Editor, устаревшая форма409, размещение, archive/restore, настоящий выбор case и порог через Datastar. Перезапуск сохранил прежнюю Editor session. QA/TD независимо вывели14 Auth writes,4 header/private-view writes и11 audit entries, учли19 view-mutating запросов, проверили все остальные строки и POST/restart equality.19 native records/38 потоков/16 PNG, outer0/PG0 и закрывающий учёт подтверждены. |
| Перенос прежних результатов | Конкретные C01–C18/subcases/F01–F03 и30 audit producers связываются с ранее принятыми конечными доказательствами и неизменными производственными компонентами. Полный исторический корпус, native fault proofs и runtime scope не подменяются количеством тестов. |
| Итоговая поставка | **OPEN:** окончательная сводная QA/TD приёмка, CI точного HEAD, полное публичное чтение ZIP/исходников и окончательный Совет. Полный R3, выпуск0.7.3 и enterprise readiness пока не приняты. |

## Неудачные попытки и устранение причин

Первый S15 downgrade остановился до PG: измеритель обнаружил изменение namespace. Применён nonce-барьер с четырьмя реальными ACK и сообщениями после завершения инструментов; новый downgrade02 прошёл строгий baseline. Измеритель не ослаблялся; первая попытка остаётся SUPERVISOR_FAILED.

Lock201 остановился до держателя из-за неверного ожидания живого bootstrap coordinator; lock202 — до Apply при чтении capture с удерживаемым writer handle. Исправлены только диагностические lifecycle и bounded file-share reader, выполнены конечные регрессии и независимые проверки. Отдельный lock203 подтвердил настоящий55P03. Оба прежних запуска остаются FAILED; отдельный холодный учёт S14 failed lock также не превращает его в PASS.

Первый draft валидатора публичного readback отклонён TD из-за неограниченного чтения Git pipe и ожидания EOF. Он сохранён отдельно; новый bounded source использует пределы8/1MiB,15 секунд и конечный EOF drain, точный Git path/SHA и новый отчёт с Flush. Его наличие не является доказательством фактического публичного скачивания.

Безопасные экраны: [Datastar](evidence/sprint15-datastar.png), [409](evidence/sprint15-stale-form.png), [Viewer](evidence/sprint15-viewer.png), [restart](evidence/sprint15-restart.png). Хеши независимых заключений и текущие изменения статуса приведены в [статусе](SPRINT_15_STATUS.md).
