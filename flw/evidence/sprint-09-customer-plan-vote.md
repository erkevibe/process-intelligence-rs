# Customer — Sprint09 exact plan vote

Vote: **FOR**.
Proposal docs/SPRINT_09_PLAN.md SHA256 **C772DA29D799DB4EF550D4A8A85E918311176642453DE040A1EBD8B10A7E2A4F**.
UTC: 2026-10-11T09:00:24.3029666Z.

Полностью прочитан план и связанное ТЗ docs/SPRINT_09_SPECIFICATION.md. Самостоятельно проверен полный hash точного плана. Это новый голос текущего фиксированного Совета, не перенос Sprint08 и не приёмка продукта.

Поддерживаю ограниченный восьмичасовой attempt закрыть исходные R3-01/02/04: owner-only archived deletion с exactID/phrase/revision/digest, отказ при active jobs, одна атомарная граница auth/repository/markers/legacy/session/survivor, cache cleanup только после результата и защита late workers; отдельный owner survivor512 без payload/secrets; versioned committed business audit и честная legacy unknown history; cleanup full corpus/realPG protocol F01/F02/F03, identity/offline leases/full state/no physical shrink и safety budgets. Пользовательская ценность — управляемое освобождение ненужных данных при сохранении доказательства действия и проверенного пути восстановления.

Принимаю явно обоснованное отклонение моего предпочтения обязательного backup UI gate: полный offline backup/newrestore не может правдиво считаться проверенным для каждой изменяющейся auth session по UI галочке. Вместо fake verified backup обязательна видимая до подтверждения необратимость без заранее сохранённой копии, отсутствие обещания recover/delete erasure, и настоящая независимая full backup/newrestore recovery проверка на owned resources. Это сознательный product contract, не разрешение скрыть риск. Архивирование остаётся безопасным обратимым вариантом.

Обязательные пределы: blueprint не считается выполненными C01–18/F01–03. Необнаруженная точная PG boundary/неполный исторический corpus/неуложившийся budget исключают опасный Apply и оставляют DISK01 OPEN. Frozen candidate не позже14:40, ≥90мин independent QA/TD/Customer+public delivery, реальные новые final votes. R3-01/02/04 исходные definitions не ослаблены; частичная поставка не даёт fullR3/R2–R5 enterprise credit. Protected installations не трогаются, текущий голос не разрешает runtime/data действия на них.

Исходная Customer позиция91854EA980E26B6E00405DF411FEB7BE52C8782215A9427F6E395D839EF1D435 сохранена. Новый emotional advisory ещё не получен; прежняя фактическая перспектива ясности irreversible/recovery учитывается без выдуманного согласия или шестого голоса. План позволяет начать bounded implementation после действительного решения большинства; mandatory independent objections остаются STOP.
