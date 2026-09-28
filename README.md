# OpenMetadata: сборка дистрибутива из готовых jar

Эта ветка собирает дистрибутив и Docker-образ OpenMetadata **без компиляции исходников**.
Все артефакты `org.open-metadata:*` берутся в опубликованном виде (Maven Central через Nexus),
а уязвимые транзитивные библиотеки заменяются на уровне Maven `dependencyManagement`.

Ветка не имеет общей истории с upstream: файлы, которые нужны дистрибутиву в рантайме
(`bin/`, `conf/`, `bootstrap/`, `LICENSE`, `NOTICE`), импортируются из upstream-тега одним
коммитом «Import OpenMetadata X.Y.Z runtime files», в сообщении которого указан тег и его sha.
Сейчас это `2.0.2-release`. Исходников upstream в ветке нет, за ними ходите в
[open-metadata/OpenMetadata](https://github.com/open-metadata/OpenMetadata).

Версия upstream задаётся одним свойством `openmetadata.version` в [pom.xml](pom.xml).
Версия сборки (`ru.sber.datalake:omd-platform`) независима и имеет вид
`<openmetadata.version>-sber.N`, где `N` растёт с каждым патч-релизом.

## Как это работает

```
pom.xml                         список патчей: BOM-импорты и точечные пины версий
├── openmetadata-shaded-deps/   пересборка двух shaded-jar с поисковыми клиентами
│   ├── elasticsearch-dep/      org.open-metadata:elasticsearch-deps:<openmetadata.version>
│   └── opensearch-dep/         org.open-metadata:opensearch-deps:<openmetadata.version>
├── openmetadata-dist/          tar.gz: bin/ conf/ bootstrap/ libs/  + проверки classpath
├── openmetadata-docker/        Docker-образ из tar.gz
├── tools/check-dist.sh         jdeps, дубли классов, сравнение с libs.lock
├── tools/compare-upstream.sh   libs.lock против набора jar, который upstream кладёт в свой дистрибутив
├── bin/ conf/ bootstrap/       скрипты запуска, конфиг и SQL-миграции (импорт из upstream-тега)
├── LICENSE NOTICE              лицензия upstream (Apache 2.0), импорт из тега
└── Jenkinsfile
```

Импортированные файлы отличаются от тега в двух местах: `bootstrap/openmetadata-ops.sh` подключает
`conf/openmetadata-env.sh` и передаёт `$OPENMETADATA_OPTS` в JVM, демо-ключи `conf/*.der` не
импортируются.

**Почему пинов в `dependencyManagement` достаточно.** Maven применяет `dependencyManagement`
модуля-потребителя ко всему транзитивному графу. Пин в корневом pom меняет версию библиотеки
во всех местах, где её тянет `openmetadata-service`, без правки upstream-овских pom.
Родительский pom сервиса (`org.open-metadata:platform`) берётся из Central как есть.

**Зачем импортируется `platform` как BOM.** Обратная сторона того же правила: `dependencyManagement`
самого upstream к нашему графу не применяется, он действует только внутри upstream-овского reactor.
Без него библиотеки, которые upstream закрепляет у себя (`reactor-core`, `okhttp`, `gson`…),
разрешались бы у нас по принципу «ближайший побеждает» и расходились с upstream-овским
дистрибутивом. Импорт `org.open-metadata:platform:<openmetadata.version>` со `scope=import`
переносит upstream-овский `dependencyManagement` в наш и закрывает разрыв автоматически.
Приоритет: явные записи в нашем pom выше импорта, среди импортов побеждает объявленный раньше,
поэтому наши BOM семейств и пины остаются сверху. Есть одно следствие: библиотека, которую upstream
управляет, а мы нет, разрешится в **upstream-овскую** версию, даже если транзитивно доступна более
новая. Так, `commons-compress` и `commons-lang3` пришлось закрепить явно, чтобы импорт не опустил их.

**Почему пересобираются `elasticsearch-deps` и `opensearch-deps`.** Upstream публикует их как
uber-jar с незарелоцированными копиями Jackson, HttpComponents 5, SLF4J и Jakarta JSON. Такие
копии нельзя обновить пином, и они перекрывают обычные jar на classpath. Модули собирают те же
jar с теми же relocations (`es.*`, `os.*`), но без этих библиотек. Координаты артефактов
совпадают с upstream, поэтому в reactor они подменяют опубликованные.

## Сборка

```bash
# дистрибутив + проверки (без Docker)
mvn -pl openmetadata-dist -am verify

# без UI
mvn -pl openmetadata-dist -am verify -DonlyBackend

# Docker-образ (нужен доступ к базовому образу и docker daemon)
mvn package -Ddocker.repo=<registry>
```

Результат: `openmetadata-dist/target/openmetadata-<version>.tar.gz`.

Требования: JDK 21, Maven 3.6+, `bash`, `unzip` (или `jar` из JDK) для проверок.

## Pipeline: package → verify → deploy

Три этапа, каждый это одна фаза Maven из корня репозитория. Maven всегда проходит жизненный цикл
с начала, поэтому `verify` повторяет `package`, а `deploy` повторяет оба: это плата за то, что
каждый этап самодостаточен и не зависит от способа вызова. Повтор стоит около 15 секунд, при этом
на этапе `deploy` в Nexus уходит ровно тот tar.gz, который прошёл проверки в том же вызове.

```bash
# 1. package: shaded-jar → tar.gz → docker build
mvn -B -ntp clean package -Ddocker.repo=$REGISTRY

# 2. verify: проверки classpath (jdeps, дубли, libs.lock, smoke-тесты)
mvn -B -ntp verify -Ddocker.repo=$REGISTRY

# 3. deploy: tar.gz в Nexus, push образа
mvn -B -ntp deploy -Ddocker.repo=$REGISTRY -Durl=$NEXUS_URL -DrepositoryId=$NEXUS_SERVER_ID
```

Порядок внутри reactor: shaded-модули → `openmetadata-dist` → `openmetadata-docker`. Образ не
собирается и не публикуется, если дистрибутив не прошёл проверки.

Флаги:

| Флаг | Действие |
|---|---|
| `-Ddocker.skip=true` | не собирать и не публиковать Docker-образ (штатный флаг fabric8), daemon не нужен |
| `-Dsmoke.skip=true` | пропустить проверки на `verify` |
| `-Dlock.mode=update` | пересчитать `libs.lock` и baseline дублей вместо сравнения |
| `-Ddocker.tag=<tag>` | тег образа, по умолчанию версия проекта |
| `-DonlyBackend` | дистрибутив без UI |

- `url` и `repositoryId` это стандартные параметры `deploy:deploy-file`; `repositoryId` должен
  совпадать с `<server><id>` в `settings.xml`, где лежат учётные данные Nexus. Без них Maven
  останавливает `deploy` сообщением о недостающем параметре.
- Артефакт в Nexus: `ru.sber.datalake:openmetadata:<version>:tar.gz:distrib`.
- Release-репозиторий не принимает одну версию дважды: перед публикацией поднимайте `-sber.N`.

## Проверки, встроенные в сборку

Выполняются на фазе `verify` модуля `openmetadata-dist`. Отключить: `-Dsmoke.skip=true`.

| Проверка | Что ловит |
|---|---|
| `OpenMetadataApplication check conf/openmetadata.yaml` на `target/libs` | главный класс не грузится, несовместимый Jackson, битый конфиг |
| jdeps по `openmetadata-service` | классы, на которые ссылается сервис, отсутствуют на classpath |
| `tools/JdbiAttachSmoke.java`: attach всех DAO-интерфейсов сервиса к JDBI над заглушкой JDBC | версия JDBI, под которую сервис не скомпилирован (`ClassCastException` на `Handler`); `check` до этого не доходит, миграции на стенде падают |
| дубли классов между jar | второй экземпляр библиотеки, который перекроет первый в зависимости от порядка `libs/*.jar` |
| `libs.lock` | любое изменение набора jar в дистрибутиве |
| `requireUpperBoundDeps` (только предупреждения в логе) | пин ниже версии, которую требует кто-то из зависимостей |

`openmetadata-dist/libs.lock` и `openmetadata-dist/duplicate-classes.baseline` лежат в git.
После **осознанного** изменения зависимостей обновите их и закоммитьте вместе с pom:

```bash
mvn -pl openmetadata-dist -am verify -Dlock.mode=update
```

Diff `libs.lock` в pull request показывает ревьюеру, что именно изменилось в runtime-наборе.
Baseline дублей это «храповик»: пары jar, которые пересекаются уже в upstream, допускаются,
новые пары валят сборку.

## Как добавить пин под CVE

1. Найдите артефакт в `libs.lock`, чтобы понять текущую версию.
2. Добавьте запись в `dependencyManagement` корневого pom с комментарием: upstream-версия и причина.
   Для семейств библиотек (Jackson, Jetty, Netty, JDBI, SLF4J) меняйте свойство BOM-импорта, а не отдельные артефакты.
3. `mvn -pl openmetadata-dist -am verify -Dlock.mode=update`, проверьте diff `libs.lock`.
4. Если библиотека упакована внутрь чужого jar, пин не поможет. См. «Ограничения».

Если пин требует `exclusions`, версию указывать обязательно: запись в `dependencyManagement`
полностью замещает запись из импортированного BOM, и без версии она станет пустой.

## Обновление версии OpenMetadata

Два коммита: импорт файлов нового тега и адаптация сборки. Merge или rebase на тег не делайте:
ветка не имеет общей истории с upstream, и это намеренно.

1. Заберите тег: `git fetch origin tag <ver>-release` (`origin` указывает на upstream).
2. Замените импортированные файлы версиями из тега:
   ```bash
   git rm -rq bin conf bootstrap LICENSE NOTICE openmetadata-shaded-deps/*/src
   git checkout <ver>-release -- bin conf bootstrap LICENSE NOTICE openmetadata-shaded-deps/*/src
   git rm -f conf/private_key.der conf/public_key.der
   git checkout HEAD -- bootstrap/openmetadata-ops.sh
   ```
   Проверьте `git diff <prev-tag> <ver>-release -- bootstrap/openmetadata-ops.sh bin/openmetadata.sh`:
   если upstream менял эти файлы, перенесите изменения в наши версии.
   Закоммитьте: «Import OpenMetadata <ver> runtime files (tag <ver>-release, <sha>)».
3. Обновите `openmetadata.version` в корневом pom, `<version>` в `openmetadata-shaded-deps/*/pom.xml`
   (enforcer проверит совпадение) и версию сборки до `<ver>-sber.1` во всех pom.
4. Сверьте версии `elasticsearch-java` и `opensearch-java` с upstream-овскими
   `openmetadata-shaded-deps/*/pom.xml` из тега (`git show <ver>-release:openmetadata-shaded-deps/...`);
   проверьте, не появились ли новые shaded-артефакты. Сверьте зависимости
   `openmetadata-dist/pom.xml` с upstream-овским (`git show <ver>-release:openmetadata-dist/pom.xml`).
5. Сверьте пины с тем, что upstream реально кладёт в дистрибутив:
   `tools/compare-upstream.sh <ver>` разрешает граф `openmetadata-service:<ver>` с родительским
   `platform:<ver>` (то есть с upstream-овским `dependencyManagement`) и печатает jar, которых нет
   в `libs.lock`, и наоборот. Всё, где наша версия ниже upstream-овской, это устаревший пин:
   снимите его или поднимите. Всё, где выше, это осознанный пин, убедитесь, что он ещё нужен.
6. `mvn -pl openmetadata-dist -am clean verify -Dlock.mode=update`, просмотрите diff `libs.lock`.
7. Закоммитьте адаптацию отдельным коммитом.

## Ограничения подхода

- **openmetadata-ui** это webpack-бандл. JS-зависимости внутри него не патчатся без пересборки фронтенда.
- **Классы сервиса** скомпилированы под конкретные API библиотек. Наличие классов проверяет jdeps,
  но не совместимость их сигнатур. Известный случай: JDBI нельзя поднимать выше 3.37.x, с 3.38.0
  обработчики SqlObject перестали реализовывать `Handler`, и `handle.attach(MigrationDAO)` падает с
  `ClassCastException`. Для JDBI это ловит `JdbiAttachSmoke`; для других библиотек финальная проверка
  это запуск на стенде с БД.
- **Shaded-jar** упаковывают чужие библиотеки внутрь себя. Сейчас это два поисковых клиента, и они
  пересобираются здесь. При обновлении upstream список нужно перепроверять.

## Секреты

Ключи для подписи JWT (`conf/private_key.der`, `conf/public_key.der`) в репозитории **не хранятся**.
Upstream-овские демо-ключи публичны и не должны использоваться. Сгенерируйте пару под стенд и
передайте её через переменные окружения `RSA_PRIVATE_KEY_FILE_PATH` и `RSA_PUBLIC_KEY_FILE_PATH`
или смонтируйте в `conf/` контейнера:

```bash
openssl genrsa -out private_key.pem 2048
openssl pkcs8 -topk8 -inform PEM -outform DER -in private_key.pem -out private_key.der -nocrypt
openssl rsa -in private_key.pem -pubout -outform DER -out public_key.der
```
