# Customer — new audit import trust policy vote

Vote **FOR** exact docs/SPRINT_09_AUDIT_IMPORT_POLICY.md SHA256 **47B40B17E5F554807C3DA97F9CC4B552730837D53DC7324D70AC41D04D6D5250**.
UTC 2026-10-11T10:10:48.4210398Z.

Полностью прочитано точное предложение, full hash проверен самостоятельно. Это новый Council policy vote, не runtime PASS/criterion acceptance. Независимый QA ordinary Writer counterexample и TD cause сообщены; Customer не выполняла этот spoof и не приписывает себе его проверку.

Поддерживаю сохранение всех imported history IDs/time/action/sequence/count/order с explicit project_backup_unverified и снятием trusted policy/outcome. Иначе пользователь читает клиентскую выдумку как подтверждённое серверное действие. Удаление истории тоже неверно: происхождение и недоверие надо объяснить, а не скрыть. Server-generated restoration event должен атомарно отражать настоящий результат и validated original repository digest/import policy/count, не подтверждать исторический actor/time. Полный offline PostgreSQL recovery сохраняет байты и доверенные witnesses, не проходит client-import normalization.

UI обязан различать «Подтверждено этим сервером», «Политика/результат не сохранены» и «Импортированная история — не проверена». Нельзя оставлять общий заголовок «успешные действия» над всеми тремя или выдавать explicit origin за цифровую подпись. Export обязан сохранять маркер, repeat import не повышает доверие. Новые настоящие действия в restored проекте получают normal committed записи; чужие historical IDs не превращаются в текущие права.

Все named independent cases предложения обязательны на новом exact candidate: forged valid Writer event, legacy/current/repeatedimport conservation, unknownorigin/imported+committed refusal, genuine append, currentrole/CAS/failure full nochange, restart/export/stockfullrecovery. Правильная архитектурная политика не заменяет actual rerun. Frozen plan/spec неизменны; protected installations untouched. Нет обещания tamperproof против DB administrator или полного security ledger.
