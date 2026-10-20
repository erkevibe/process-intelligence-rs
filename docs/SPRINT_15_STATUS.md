# Sprint15 — техническая приёмка R3

Совет принял исходный конечный объём R3 пятью реальными голосами. [Решение](../flw/evidence/sprint-15-final-decision.json) действует после всех перечисленных проверок поставки; их фактический итог, точный финальный HEAD и два CI приведены в квитанции [релиза0.7.3](https://github.com/erkevibe/process-intelligence-rs/releases/tag/v0.7.3). Само голосование не закрывает отсутствующую проверку. [Отчёт](SPRINT_15_REPORT.md), [инструкция](SPRINT_15_RUN_GUIDE.md), [матрица](SPRINT_15_R3_MATRIX.json), [план](SPRINT_15_PLAN.md).

| Область | Принятый конечный результат |
|---|---|
| R3-01: проекты, папки, доступ | Жизненный цикл, перенос между папками списка проектов с сохранением участников/прав/данных; один303 и один409 для пересекающихся запросов общей ревизии;403 прежней сессии Editor после demotion и успешное действие после восстановления роли. |
| R3-02: бизнес-аудит |30 action-specific producer/policy контрактов, точный перенос неизменных путей и новые реальные контексты; атомарность, порядок, retention512/513, export, недоверенное происхождение импортированного аудита.12 конкретных повреждённых Auth/catalog/audit состояний отказали с сохранением данных и ACL. |
| R3-03: сохранность и миграции | Полный historical forward/partial/resume, чтения/записи/RBAC/restart, backup в новую restore-базу. Настоящий старый0.6.1 отказал до listener; это общий отказ Auth decoder, не исключительная причинность папок. |
| R3-04: offline cleanup | Исходные53 C/F строки с отдельными finite scope; настоящий lock2/55P03, statement5/transaction10, lease/identity/conservation, F01–F03 и reconciliation. Успешный backup не заменяет cleanup proof. |
| Браузер/Datastar |54 фактических шага Owner/Viewer/Editor, устаревшая форма409, перенос/archive/restore, выбор case и порог; та же Editor session после restart. Независимо выведены14 Auth writes,4 private-view/header writes и11 audit entries; остальное состояние сохранено. |
| Доставка | Анонимный полный ZIP E798 и1103 файла точного core source независимо проверены QA/TD; все1754 payload файла совпали с manifest. Новая установка публичного Start.ps1/PS7 и restart выполнены на отдельной свежей копии тех же байтов. |

Кандидат неизменен: EXE `23563DFF8FE93F339AD7F12FD0783AC3E2C53B8D9368C00D772A8FBABBE5F292`, ZIP `E79866DA3E9348CFA3EA08542D1A9FB405A47D9F7C5AE15F56979A4559AE3A4C`, build core `3f0b3caa34b9b4beaf4422f78c2e31c0f97d3209`. Диагностические коммиты содержат проверки/документы; они не являются исходником сборки EXE. Финальный docs-only HEAD и его CI фиксируются квитанцией релиза.

Поддержанный путь — PowerShell7. Windows PowerShell5.1 не проверен и не заявляется. README0.7.2 внутри замороженного ZIP раскрыта в текущей инструкции; архив не перепакован. Отдельные failed попытки остаются failed. Конечные переносы прежних доказательств не означают новые runtime для всех30 действий или любых повреждений. Полная совместимость с Apromore, R2/R4/R5 и enterprise readiness остаются открытыми.

## Независимые заключения

| Проверка | SHA256 QA | SHA256 TD |
|---|---|---|
| race/отзыв прав |867C2449DC5176BC08C65FB7B65C3C64EB73338DFCE7EE57D1C01A8B620E5A95|CF8176E039AF6918220226D13FEA23C61AAFDC1917D8F75EC406282289364AE2|
| old0.6.1 |DC5E967135093CC8EB4657C23E5E422FE91077F7C259BF55DADBC1F168A59154|57C0B51869BAD65CBB21B6D945FB173E85CC47805A68B27ECFE265A08CC9D57D|
| lock203 |C45D78BA4FCE9761FA9E69F8E78CCE38275ECBBD842E3BB044537B20D5A5D609|FDC4292CE15EF1C4B48EE92580EF02F183139F6DBED9A6089CCA038CEF93B0E8|
| negative12 |CBE9F7805C757C78E3B8A6DC8B8C505C0466D7E734745377026FD7BA75848AAF|D468CC3B725935A444060CA968B605E012BADB884AD1967E9E53931F8E9BDE33|
| browser02 |E1F8F02C682D698A733EE3F226DA17FFF467ABAD0D3B262C6877CC04BABFA6DE|4CD05F7BC0FF9042044047B5C3B0A92FF70D4E8C417AA198B51EBCDFF4874D46|
| public02 |E9DEF427D0F0AABFDAE2C394070C4DD69711C0012E1C2BCDBEB8F0D7EAD8DBBE|ED0D339EC42476CE4B3F712D193A55D7075328C4F3BB8CB72DDC7DD0144EF52E|
| функциональная матрица |058701FA29441F29C84DE08119768BC0A71DA6BAD6DC65E70BDEAD01F05A1A53|929023778C6FA8217D086F8AB985D30AA9B8B59C319168EA777E2C0410E12C71|

PM mapping `2DE72488B3D40182069AAE722B45172057877FA1B4CAEEE9616FF17529DC7680`; публичная матрица `E015B1E4F36BC1312F0F5E9B700A5F65ACCC63E8354D80AF0BC7AAFEB79E9ABC`. Позднейшие фактические голоса QA/TD отдельно приняли интегрированную матрицу вместе с readback, сохранив условия финального HEAD/CI/метаданных/ресурсов. Их точные хеши опубликованы в решении Совета.

Фактические экраны: [Datastar](evidence/sprint15-datastar.png), [409](evidence/sprint15-stale-form.png), [Viewer](evidence/sprint15-viewer.png), [restart](evidence/sprint15-restart.png). Снимок экрана не заменяет полную независимую сверку состояния. Приёмка Customer — голос представителя в команде; окончательная приёмка пользователя не заявляется.
