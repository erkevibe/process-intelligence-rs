# Sprint04 — PM product flow review и отдельные перспективы FLW

Read-only existing PM /root/pm_final, отдельный от Customer источник, одно Council место. Read docs/STORAGE_V2.md, tools/migrate-storage.ps1/start-packaged.ps1/run-windows.ps1 и конкретные package-windows generatedStart/packagedinput строки. No runtime/document edits outside this evidence. AcceptedS4-P1 неизменен; no release vote. Draft10projects/94records mapping и baseline13.2–13.65s/WorkingSet2.107GB известны от координатора, не новый independentQA PASS от PM; finalfault/performance/package pending.

## Пользовательский путь: что уже понятно

Migration helper явно offline, не bootstrap/reset; проверяет canonical package manifest, private-config directory ACL и SHA/bytes backup. Database target аргумент позволяет named restoredcopy, Start.ps1 передаёт его launcher. Helper сохраняет прежний envURL и не печатает credentials. Recognizedv1 normalstartup controlledmigration_required; source rows retained/inert, staged equality/version/checksum и globalpublication boundary описаны. «Migration did not complete» не выдаётся за успех; oldbinary наmigratedDB unsupported. Lazyfirstload/cache residual и runtimeperphase deadlines честно названы.

## Actionable clarity перед freeze

1. **Добавить законченный restored-copy quickstart**. Current docs говорят «copy's private configuration», но migration helper требует config/backup внутри **новой установки .local**, а Start вызывает setup собственного каталога. Если человек восстановит DB в oldcluster, а затем запустит новый пакет с default/newcluster, он может открыть другой target. Копирование одного старого config в пустую новую .local тоже не полноценная установка (completedconfig без соответствующего PG_VERSION отклоняется). Безопасный пример: original0.3backup → initialize отдельный new0.4cluster на свободном порту без измененияold → copy backup+manifest в new.local/backups → restore в newcluster/newpi_restore_* → explicit migrate -Database samepi_restore_* → Start с **тем же Database/PostgresPort** и отдельным HTTPPort. До каждого шага указывать installation/cluster/database; не переносить privateconfig как заменуcluster. Исходныйoldcluster остаётся rollback источником.
2. **Показать точные public-helper команды с placeholders**, без ручного PI_DATABASE_URL/password. Docs сейчас содержат один internalEXE option, но не полный `tools/migrate-storage.ps1 -BackupFile ... -Database pi_restore_...` и `Start.ps1 -Database ... -PostgresPort ... -Port ...`. Выбор существующегоtarget должен быть явным в примере: migration helper default process_intelligence не означает, что restoredcopy выбран автоматически.
3. **Banner для restoredDB**: «create your account on first start» корректно для freshDB, но восстановленная база использует сохранённые accounts/session. Дописать «для новой пустой базы; в восстановленной войдите прежней учётной записью». Не приглашать создавать второйadmin при восстановлении и не обещать переноса browser-cookie между любымиDB.
4. **Completed vsrefused**: перечислить безопасные nextsteps: runningapp остановить; unknownstage/checksum/config mismatch сохранить files/logs/backup, исправить причину; послеsuccessfulmigration проверитьknownexports/login прежде чемвыбиратькопиюдляработы. Repeating commands не должен подразумевать reset; отказ notcompleted.
5. **Лимиты**: устранение aggregate JSONBcap не снимает8logs/64models/input/perrecord bounds и не обещаетmemoryscalability. Start metadata benefit отдельно отfirstprojectload/cachedprojectmemory. Baseline≈2.1GB sampledWorkingSet — фактическаяbaseline, не разрешение скрытьPG/sharedmemory или заявить2.1GBsaved без candidate measurements.

Это flow recommendations внутри утверждённого deployment/docs scope; не требуют нового человеческого permission. Root owns production/docs fixes, QA independently exactnative helperchain+manifest+target/backup guards beforerelease. PM не исполнял migration againstuser installations.

## Девять отдельных PM эмоциональных перспектив

Это аналитические lenses факт→проблема→предложение, не мысли/чувства человека, не девять голосов и не replacementCustomer.

| Перспектива | Факт | Проблема | Предложение |
|---|---|---|---|
| Радость | Storagev2 разделяет тяжёлыеlogs иsmallstate | Польза может потеряться за названиямитаблиц | Объяснить «изменение подписи/параметра больше не переписывает весьпроект», подкрепивactualdelta measurements |
| Печаль | Oldrows остаются inert изанимаютdisk | Фраза «новаяструктура» можетсоздатьожиданиеосвобожденияместа | Сказать source-retention intentional, cleanupfuture afterverifiedbackup, no diskspace-savingclaim |
| Гнев | Helper explicitDatabase иStart тотжearg, defaultдругаяDB | Разныеtargets могутдатьвидимостьпотерянногопроекта | Законченныйquickstart sameinstallation/DB/PGPort накаждомшаге, явныйrestoredtarget |
| Страх | Offline migration неограниченаtotal15s, sourceintactuntilpublication | ОстановкаCLI можетказатьсяпотерейданных | Показать resumedvscompleted state/безопасныйповтор ссохранённымbackup; не reset |
| Отвращение | Config содержитпароль, dumpauth/sessions, helperнепечатаетURL | Public instructions могутпредложитькопироватьsecretsвconsole/chat | Толькоsuppliedhelper/privatepaths иpublichashes; dump/config не публиковать |
| Тревога | Unknownstage exact-equality mismatch controlledrefuses | Человекунепонятно, ждатьилиперезапускать | Назватьпричину/следующийшаг/старуюкопию, отказненазыватьcompleted; protectfiles/logs |
| Зависть | Lazyready ужеотделёнотfirstload, cachedwholeproject остаётся | Startup improvement можно принятьзаenterprise scale | Отдельныеready/firstload/mutation/RSS values иявныйcachelimit/no64worstprojects |
| Стыд | Launch banner предлагаетaccountcreation, восстановленнаяDBужеимеетaccounts | Пользовательможетвыбратьнеправильныйfirst-accountflow | Различитьfreshaccount иexistinglogin; verifyknownexports beforeadoption |
| Скука | Packagingverifies manyfiles, migrationmultiphase | Длиннаяоперация можетвыглядетьзависшей | Краткие этапыverification/migrating/completed сбезопаснымиcounts/status, неSQL/secrets; preservefinitefaultchecks |

QA actualmigrationinterrupt/fullrowpreservation/deltawrites/same100k/timeRSS remain mandatory. Prior drafts/numericbaseline неcompletion. Final90min21:27:49UTC/deadline22:57:49UTC/live3000/3010/3030 unchanged. No scopeexpansion/newCouncilvote.
