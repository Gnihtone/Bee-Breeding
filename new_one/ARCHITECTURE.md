# GTNH Bee Breeder — Архитектура

## Задача

Автоматизация разведения пчёл в модпаке GregTech: New Horizons (GTNH) с использованием OpenComputers.

**Цель:** По заданному целевому виду пчелы автоматически:
1. Построить путь мутаций от доступных видов к целевому
2. Последовательно выполнить все мутации
3. Получить **1 стак из 64 дронов** + 1 принцессу целевого вида

**Особенности:**
- Поддержка акклиматизации (изменение tolerance для climate/humidity)
- Автоматический анализ пчёл для определения вида и чистоты
- Управление foundation-блоками для мутаций
- Интеграция с ME-сетью для хранения и выдачи пчёл/материалов
- Обработка побочных мутаций ("исправление" принцесс чужих видов)
- Пропуск мутаций со специальными условиями (дождь и т.д.)

---

## Структура модулей

```
┌─────────────────────────────────────────────────────────────────┐
│                          main.lua                               │
│  - Точка входа                                                  │
│  - Парсинг аргументов (main all / main <species>)               │
│  - Discovery устройств                                          │
│  - Построение пути мутаций (pathfinder)                         │
│  - Рекурсивный ensure_species                                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                       orchestrator.lua                          │
│  - Выполнение одной мутации (parent1 + parent2 → child)         │
│  - Загрузка начальных пчёл из ME                                │
│  - Цикл разведения: breed → analyze → consolidate → acclimatize │
│  - Обработка ошибок: запрос пчёл из ME при нехватке             │
│  - Очистка буфера: trash_invalid_drones, clean_buffer           │
│  - Сортировка результата: pure → ME, hybrids → trash            │
└─────────────────────────────────────────────────────────────────┘
         │              │              │              │
         ▼              ▼              ▼              ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ apiary_proc  │ │analyzer_proc │ │acclimatizer_ │ │ foundation   │
│              │ │              │ │    proc      │ │              │
│ - breed_cycle│ │ - process_all│ │ - process_all│ │ - ensure()   │
│ - выбор пчёл │ │ - анализ     │ │ - проверка   │ │ - установка  │
│   для        │ │   стаками    │ │   tolerance  │ │   блока под  │
│   скрещивания│ │              │ │ - загрузка   │ │   пасекой    │
│ - scan_buffer│ │              │ │   реагентов  │ │              │
└──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘
```

---

## Конфигурация

### `config.lua`
**Централизованный файл конфигурации.**

```lua
return {
  -- Цели разведения
  DRONES_NEEDED = 64,              -- Требуемое количество дронов в одном стаке
  INITIAL_DRONES_PER_PARENT = 16,  -- Дронов каждого родителя из ME
  
  -- Акклиматизация
  MIN_TOLERANCE_LEVEL = 3,         -- Минимальный уровень tolerance
  MAX_TOLERANCE_LEVEL = 5,         -- Максимальный уровень tolerance
  REAGENT_COUNT = 64,              -- Количество реагентов за раз
  
  -- Реагенты для акклиматизации
  CLIMATE_ITEMS = {
    HELLISH = "Blizz Powder",
    HOT = "Ice",
    WARM = "Ice",
    COLD = "Lava Bucket",
    ICY = "Lava Bucket",
  },
  HUMIDITY_ITEMS = {
    ARID = "Water Can",
    DAMP = "Coal Dust",
  },
  DEFAULT_CLIMATE_REAGENT = "Ice",
  DEFAULT_HUMIDITY_REAGENT = "Water Can",
  
  -- Слоты акклиматизатора
  CLIMATE_SLOT = 6,
  HUMIDITY_SLOT = 7,
  
  -- Таймауты
  DEFAULT_CYCLE_TIMEOUT = 600,
  DEFAULT_ANALYZE_TIMEOUT = 120,
  
  -- Файлы данных
  MUTATIONS_FILE = "/home/data/mutations.csv",
}
```

---

## Модули

### `main.lua`
**Точка входа программы.**

Команды:
- `main` — показать usage
- `main all` — разводить все достижимые виды волнами
- `main <species>` — разводить конкретный вид (рекурсивно с родителями)

Логика:
1. Discovery устройств по маркерам `ROLE:*`
2. Загрузка данных мутаций (`bee_data_parser`)
3. Проверка stock в ME (`bee_stock`)
4. Построение пути (`pathfinder`)
5. Рекурсивный `ensure_species` → вызов `orchestrator:execute_mutation`

---

### `orchestrator.lua`
**Выполняет одну мутацию.**

Входные данные:
```lua
mutation = {
  parent1 = "Forest",
  parent2 = "Meadows", 
  child = "Common",
  block = "none"  -- или "minecraft:sand" и т.д.
}
```

Цикл работы:
1. Определить requirements (climate/humidity) из NBT целевой пчелы
2. Установить foundation-блок (если нужен)
3. Загрузить начальных пчёл из ME (1 принцесса + 16 дронов каждого родителя)
4. **Цикл разведения:**
   - `apiary:breed_cycle()` — один цикл в пасеке
   - Обработка ошибок:
     - "no princess" → запрос из ME
     - "no suitable drone" → запрос родительских дронов из ME
   - `analyzer:process_all()` — анализ всех пчёл стаками
   - `utils.consolidate_buffer()` — объединение одинаковых пчёл
   - `trash_invalid_drones()` — удаление дронов ненужных видов
   - Проверка: **1 стак из 64** дронов + 1 принцесса целевого вида?
   - `acclimatizer:process_all()` — акклиматизация для след. цикла
5. `clean_buffer()` — очистка буфера от лишних пчёл
6. Сортировка: pure → ME, hybrids → trash

**Обработка побочных мутаций:**
Если получена принцесса "чужого" вида (не target/parent1/parent2), она используется для "исправления" — скрещивается с родительскими дронами.

---

### `apiary_proc.lua`
**Управление Forestry Apiary.**

Слоты пасеки:
- 1: Princess (input)
- 2: Drone (input)
- 3-5: Frame slots
- 6-12: Output slots

**Логика выбора дронов для скрещивания:**

| Принцесса     | Приоритет дронов        | Причина                    |
|---------------|-------------------------|----------------------------|
| **parent1**   | parent2 > parent1       | Скрещиваем для мутации     |
| **parent2**   | parent1 > parent2       | Скрещиваем для мутации     |
| **target**    | target > parent1 > parent2 | Закрепляем вид          |
| **вид4 (чужой)** | parent1 > parent2    | Исправляем принцессу       |

**Важно:** Принцесса родительского вида **НЕ** скрещивается с дроном целевого вида — только с родителями!

---

### `analyzer_proc.lua`
**Анализ пчёл через Forestry Analyzer.**

Слоты анализатора:
- 7: Input slot (bee)
- 2: Honey slot
- 8: Output slot

Особенности:
- Анализирует **стаками** (до 64 пчёл за раз)
- После анализа возвращает пчёл в буфер
- Оптимизирован: использует `getAllStacks()` для сканирования

---

### `acclimatizer_proc.lua`
**Акклиматизация через GT Acclimatiser.**

Слоты:
- 1-5: Bee slots (5 = output, недоступен для транспозера)
- 6: Climate reagent slot
- 7: Humidity reagent slot
- 9: Output slot (акклиматизированная пчела)

**Реагенты:**
```lua
CLIMATE_ITEMS = {
  HELLISH = "Blizz Powder",
  HOT = "Ice",
  WARM = "Ice",
  COLD = "Lava Bucket",
  ICY = "Lava Bucket",
}
HUMIDITY_ITEMS = {
  ARID = "Water Can",
  DAMP = "Coal Dust",
}
```

**Логика акклиматизации:**

Пчела **нуждается** в акклиматизации если:
1. Её native climate ИЛИ humidity **не** "Normal"
2. И она **не** уже акклиматизирована

Пчела **акклиматизирована** если:
- Оба параметра tolerance >= 3
- И хотя бы один параметр tolerance == 5

**Процесс:**
1. Загрузить 64 реагента climate в слот 6
2. Загрузить 64 реагента humidity в слот 7
3. Загрузить пчелу (принцессу или 1 дрона)
4. Ждать вывода в слот 9
5. Пополнять реагенты при необходимости
6. Вернуть в буфер

---

### `pathfinder.lua`
**Построение пути мутаций.**

```lua
local path = pathfinder.build_path(mutations, stock, target_species)
-- Возвращает список мутаций в порядке выполнения
```

Использует BFS для поиска кратчайшего пути от доступных видов к целевому.

**Обработка специальных условий:**
1. Сначала пытается найти путь БЕЗ мутаций с `other != "none"` (дождь и т.д.)
2. Если не найден — ищет путь с такими мутациями и предупреждает пользователя

---

### `discovery.lua`
**Автоматическое обнаружение устройств.**

Ищет устройства по маркерам в слоте 1:
- `ROLE:BUFFER` — буфер для пчёл
- `ROLE:APIARY` — пасека
- `ROLE:ANALYZER` — анализатор
- `ROLE:ACCLIMATIZER` — акклиматизатор
- `ROLE:ACCL-MATS` — материалы для акклиматизации
- `ROLE:ME-BEES` — ME интерфейс (вход/выход пчёл)
- `ROLE:ME-MATS` — ME интерфейс (материалы)
- `ROLE:TRASH` — мусорка для гибридов
- `ROLE:FOUNDATION` — слот для foundation-блока

---

### `me_interface.lua`
**Обёртка над ME Interface.**

```lua
local me = me_interface.new(me_address, db_address)
me:list_items()                           -- список предметов в ME
me:configure_output_slot(filter, opts)    -- настроить выход
me:clear_slot(slot_idx)                   -- очистить слот после перемещения
```

Использует Database для хранения ghost-items.

---

### `mover.lua`
**Перемещение предметов между инвентарями.**

```lua
mover.move_between_nodes(src_node, dst_node, count, src_slot, dst_slot)
mover.move_between_devices(src_dev, dst_dev, count, src_slot, dst_slot)
```

---

### `utils.lua`
**Общие утилиты.**

```lua
utils.device_nodes(dev)           -- нормализация device → nodes
utils.find_free_slot(dev)         -- поиск свободного слота (getAllStacks)
utils.find_slot_with(dev, label)  -- поиск слота с предметом (getAllStacks)
utils.consolidate_buffer(dev)     -- объединение одинаковых предметов в стаки
```

**consolidate_buffer:**
Идентификация предметов по `name + label + tag` (если hasTag == true).

---

### `analyzer.lua`
**Анализ NBT данных пчелы.**

```lua
analyzer.get_species(stack)              -- имя вида (displayName)
analyzer.is_pure(stack)                  -- чистая ли пчела
analyzer.is_princess(stack)              -- принцесса или дрон
analyzer.is_analyzed(stack)              -- проанализирована ли
analyzer.get_climate(stack)              -- climate из NBT
analyzer.get_humidity(stack)             -- humidity из NBT
analyzer.get_requirements(stack)         -- {climate, humidity}
analyzer.get_temperature_tolerance(stack) -- строка tolerance (e.g. "Both 5")
analyzer.get_humidity_tolerance(stack)   -- строка tolerance
analyzer.get_tolerance_level(str)        -- число из строки (e.g. 5)
analyzer.is_acclimatized(stack)          -- проверка акклиматизации
```

**is_acclimatized:**
```lua
-- Оба tolerance >= MIN_TOLERANCE_LEVEL (3)
-- И хотя бы один == MAX_TOLERANCE_LEVEL (5)
```

---

### `bee_stock.lua`
**Проверка наличия пчёл в ME.**

```lua
local stock = bee_stock.check(me_interface)
-- stock["Forest"] = {drones = 128, princesses = 2}
```

---

### `bee_data_parser.lua`
**Парсинг данных о мутациях.**

Читает файл с данными о мутациях и возвращает структуру:
```lua
{
  mutations = {
    {parent1 = "Forest", parent2 = "Meadows", child = "Common", chance = 0.15, other = "none"},
    {parent1 = "Rocky", parent2 = "Industrious", child = "Refined", other = "Requires rain"},
    ...
  }
}
```

---

## Физическая структура

```
                    ┌─────────────┐
                    │   ME Сеть   │
                    └──────┬──────┘
                           │
              ┌────────────┼────────────┐
              ▼            ▼            ▼
        ┌──────────┐ ┌──────────┐ ┌──────────┐
        │ME-BEES   │ │ME-MATS   │ │ Database │
        │Interface │ │Interface │ │          │
        └────┬─────┘ └────┬─────┘ └──────────┘
             │            │
             ▼            ▼
        ┌─────────────────────────────────────┐
        │              BUFFER                 │
        │         (центральный сундук)        │
        └──┬──────┬──────┬──────┬──────┬─────┘
           │      │      │      │      │
           ▼      ▼      ▼      ▼      ▼
        ┌─────┐┌─────┐┌─────┐┌─────┐┌─────┐
        │APIAR││ANALY││ACCLI││TRASH││FOUND│
        │ Y   ││ZER  ││MATI ││     ││ATION│
        │     ││     ││ZER  ││     ││     │
        └─────┘└─────┘└──┬──┘└─────┘└─────┘
                        │
                        ▼
                   ┌─────────┐
                   │ACCL-MATS│
                   │(реагенты)│
                   └─────────┘
```

---

## Поток данных

```
1. Пчёлы из ME → Buffer (через ME Interface)
2. ME Interface slots очищаются после перемещения
3. Buffer → Apiary (выбор по приоритету)
4. Apiary → Buffer (результат цикла)
5. Buffer → Analyzer (анализ стаками)
6. Analyzer → Buffer
7. Consolidate: объединение одинаковых пчёл
8. Trash invalid drones (побочные виды)
9. Buffer → Acclimatizer (если нужно)
10. Acclimatizer → Buffer
11. Повтор 3-10 пока не достигнута цель (64 дронов в 1 стаке)
12. Clean buffer: все лишние пчёлы → Trash
13. Buffer → ME (чистые целевые) / Trash (остальные)
```

---

## Алгоритм выбора пчёл для скрещивания

```
Цель: Forest + Meadows → Common

Цикл 1: Принцесса Forest + Дрон Meadows → [мутация]
Цикл 2: Принцесса Meadows + Дрон Forest → [мутация]
Цикл 3: Принцесса Common! + Дрон Common (приоритет) / Forest / Meadows
...
Цикл N: Принцесса Tropical (побочная!) + Дрон Forest / Meadows → [исправление]
```

---

## Пример использования

```bash
# Разведение конкретного вида
main Industrious

# Разведение всех достижимых видов
main all
```

---

## Требования к оборудованию

- **OpenComputers Computer** с достаточной памятью (Tier 3 рекомендуется)
- **Transposers** для связи всех устройств с буфером
- **ME Interface** + **Database** для работы с ME сетью
- **Forestry Apiary** для разведения
- **Forestry Portable Analyzer** (или другой анализатор)
- **GT Acclimatiser** для акклиматизации
- **Сундуки** для буфера, мусорки, реагентов

---

## Маркеры устройств

В слот 1 каждого инвентаря нужно положить предмет с названием:
- `ROLE:BUFFER`
- `ROLE:APIARY`
- `ROLE:ANALYZER`
- `ROLE:ACCLIMATIZER`
- `ROLE:ACCL-MATS`
- `ROLE:ME-BEES`
- `ROLE:ME-MATS`
- `ROLE:TRASH`
- `ROLE:FOUNDATION`

---

## Обработка ошибок

| Ошибка | Действие |
|--------|----------|
| Нет принцессы в буфере | Запрос target/parent1/parent2 принцессы из ME |
| Нет подходящих дронов | Запрос parent1/parent2 дронов из ME |
| Принцесса чужого вида | Используется для "исправления" с родительскими дронами |
| Мутация требует дождь | Пропускается, ищется альтернативный путь |
