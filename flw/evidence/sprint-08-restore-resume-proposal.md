# S8-RESTORE01 — точное предложение о возобновлении

Статус при внесении: предложение, STOP ещё открыт. Фиксированный Совет: Root, PM, Customer, QA/ProcessAuditor, TechnicalDebt. Созыв и исходная Root позиция — sprint-08-restore-convocation.md; независимые PM/Customer/QA/TD позиции получены до этого общего предложения. Молчание не голос. Для принятия нужно более половины пяти фактических голосов.

Предлагается закрыть только причину S8-QA-RESTORE01 и возобновить затронутую разработку и проверки. Исправленный исходник d29b623d70179d6dab2863464f70aef5c97f0d47, проверенный DEBUG EXE SHA256 03F418A04E7BF6893959F095CB66506B439C63DC6D7E185122AC577622C7AE51. Обычный импорт и restore используют canonical repository_v2::prepare; strict decoder не ослаблен. Отдельная регрессия воспроизвела ошибку до исправления, затем test11/build-debug03/clippy02 завершились exit0. Авторские проверки сами не снимают STOP.

Независимая QA closure: sprint-08-qa-restore-closure01.json SHA256 391B40F87CB5696CC4D7F635FB76C7E701EE3AE14A29314F98364D12B12DF227. Fresh restore сохраняет полный исходник/историю/папки/audit; hash-valid повреждения и digest corruption не меняют SQL hashes/versions; реальный собственный restart 38384→1796 сохраняет полные hashes; backup без provenance восстанавливается, исходник/история явно недоступны. Все названные native wrapper exits0, long-lived process exit0 не выдумывается.

Независимое TD заключение: sprint-08-td-restore-closure-position.md SHA256 40B92EF4EA648CDEFC16AA06F4FF5B27C87E3386243EB7AFC73BD7F8D8A02BF3. TD прочитал corrective diff и полную QA closure, проверил все десять приложенных файлов по полным SHA/размерам; причина устранена для этого scope, targeted resume допустим.

Первичная STOP finding SHA256 815E902CBED726412BD0FADD2C852C42ABAB12FAE41DD6CAF367E9A52ECA1B08 и повреждённая D2 копия сохраняются, не исправляются на месте. Ошибочно угаданный полный source SHA в launcher metadata сохранён с отдельной явной корректировкой; неверное ожидание303 в plain verifier сохранено, continuation использовал существующий log3 без повторного импорта. Ограничения и tool-only failure остаются в отчёте.

Решение НЕ принимает релиз, frozen package, full PostgreSQL dump recovery, внешние0.5 данные, все новые функции или полное R2–R5. Оно НЕ принимает DISK01 extension. Срок09:42 UTC и freeze не позднее08:12 UTC сохраняются. Последующие изменения получают собственные регрессии и точную независимую приёмку. Новая находка STOP снова останавливает затронутый путь. Публичная поставка остаётся за окончательным решением Совета.
