# Sprint09 QA — новый голос по точному плану

Голос: FOR.

Полностью прочитан docs/SPRINT_09_PLAN.md; независимый RAW SHA256 C772DA29D799DB4EF550D4A8A85E918311176642453DE040A1EBD8B10A7E2A4F совпал. Это новый голос о плане, не исходная позиция/прежняя приёмка и не разрешение на фактическое удаление пользовательских данных.

Поддерживаю согласованное owner-only удаление заранее архивированного проекта с точным ID/явной фразой/version+digest, отказом при незавершённых jobs, одним atomic auth+repository transaction и отдельным bounded survivor witness. Безопасность требует фактических обоих порядков concurrent archive/delete/worker, актуальных session/role/CAS и полного сохранения всех нецелевых данных/sequence. Backup не подменяется галочкой: UI честно предупреждает необратимость, QA действительно проверяет full backup/newrestore отдельно.

Audit scope перечисляет все выбранные mutation groups; policy/version/parameters or digest/actor/project/resource/time/revision/committed должны сохраняться атомарно. Старые поля остаются unknown, не дописывается успех. Cleanup принимает только полный неизменный old0.3 archive, всеC01–18/subcases/F01–03, оба identity+offlinelease/full locked checks и неизменные5/2/10сек budgets. Неисполненный observer означает NOT-IN-RUN/DISK01OPEN; никакого переноса HTTP303-loss в PostgreSQL ACK доказательство.

Обязательные условия исполнения: решение Совета сообщено до новой SQL/fixture/runtime операции; privateSIDACL и owned PID+creation/path/datadir guards до процессов; TD exact protocol review до fault; freeze≤14:40 и≥90мин независимой точной приёмки. Неизвестная граница DELETE/COMMIT, full-corpus timeout, любое noncandidate изменение или false successaudit — STOP. При этом безопасный самостоятельный increment допустим только с честно оставшимся OPEN опасным критерием, не снижением исходной матрицы.

Восемь часов считаю достаточным окном попытки при раннем09:45 feasibility gate, не обещанием полногоR3. Все protected установки/DB исключены. Ожидаю явное сообщение принятого решения перед подготовкой новых копий. До него — только test-only protocol design/private source, без сетевого fault/SQL запуска.
Actual UTC: 2026-10-11T09:01:05.1381601Z
