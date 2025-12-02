# GTNH Bee Breeder — Архитектура

## Задача

Автоматизация разведения пчёл в модпаке GregTech: New Horizons (GTNH) с использованием OpenComputers.

**Цель:** По заданному целевому виду пчелы автоматически:
1. Построить путь мутаций от доступных видов к целевому
2. Последовательно выполнить все мутации
3. Получить 64 дрона + 1 принцессу целевого вида

**Особенности:**
- Поддержка акклиматизации (изменение climate/humidity предпочтений)
- Автоматический анализ пчёл для определения вида и чистоты
- Управление foundation-блоками для мутаций
- Интеграция с ME-сетью для хранения и выдачи пчёл/материалов

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
│  - Сортировка результата: pure → ME, hybrids → trash            │
└─────────────────────────────────────────────────────────────────┘
         │              │              │              │
         ▼              ▼              ▼              ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ apiary_proc  │ │analyzer_proc │ │acclimatizer_ │ │ foundation   │
│              │ │              │ │    proc      │ │              │
│ - breed_cycle│ │ - process_all│ │ - process_all│ │ - ensure()   │
│ - выбор пчёл │ │ - анализ     │ │ - смена      │ │ - установка  │
│   для        │ │   стаками    │ │   climate/   │ │   блока под  │
│   скрещивания│ │              │ │   humidity   │ │   пасекой    │
└──────────────┘ └──────────────┘ └──────────────┘ └──────────────┘
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
1. Определить requirements (climate/humidity) из NBT пчелы
2. Установить foundation-блок (если нужен)
3. Загрузить начальных пчёл из ME (1 принцесса + 16 дронов каждого родителя)
4. **Цикл разведения:**
   - `apiary:breed_cycle()` — один цикл в пасеке
   - `analyzer:process_all()` — анализ всех пчёл стаками
   - `utils.consolidate_buffer()` — объединение одинаковых пчёл
   - Проверка: 64 дрона + 1 принцесса целевого вида?
   - `acclimatizer:process_all()` — акклиматизация для след. цикла
5. Сортировка: pure → ME, hybrids → trash

---

### `apiary_proc.lua`
**Управление Forestry Apiary.**

Слоты пасеки:
- 1: Princess (input)
- 2: Drone (input)
- 3-5: Frame slots
- 6-12: Output slots

Логика выбора пчёл для скрещивания:
- Приоритет дрона нового вида (чистый → гибрид)
- Если нет дрона нового вида — взять противоположный от принцессы
- Всегда выбирать чистых в приоритете

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

---

### `acclimatizer_proc.lua`
**Акклиматизация через GT Acclimatiser.**

Слоты:
- 1: Item slot (реагент)
- 2-7: Bee slots

Реагенты:
```lua
REAGENT_MAP = {
  climate = {
    Hellish = "Thermal Expansion:material:515",  -- Blizz Powder
    Hot = "Thermal Expansion:material:515",
    -- ...
  },
  humidity = {
    Arid = "IC2:itemDust:9",  -- Coal Dust
    Damp = "minecraft:snowball",
    -- ...
  }
}
```

Особенности:
- Автоматическое пополнение реагентов из `mats_dev`
- Определяет requirements напрямую из NBT пчелы

---

### `pathfinder.lua`
**Построение пути мутаций.**

```lua
local path = pathfinder.build_path(mutations, stock, target_species)
-- Возвращает список мутаций в порядке выполнения
```

Использует BFS для поиска кратчайшего пути от доступных видов к целевому.

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
utils.find_free_slot(dev)         -- поиск свободного слота
utils.find_slot_with(dev, label)  -- поиск слота с предметом
utils.consolidate_buffer(dev)     -- объединение одинаковых предметов в стаки
```

---

### `analyzer.lua`
**Анализ NBT данных пчелы.**

```lua
analyzer.get_species(stack)       -- имя вида (displayName)
analyzer.is_pure(stack)           -- чистая ли пчела
analyzer.is_princess(stack)       -- принцесса или дрон
analyzer.is_analyzed(stack)       -- проанализирована ли
analyzer.get_climate(stack)       -- climate из NBT
analyzer.get_humidity(stack)      -- humidity из NBT
analyzer.get_requirements(stack)  -- {climate, humidity}
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
    {parent1 = "Forest", parent2 = "Meadows", child = "Common", chance = 0.15},
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
1. Пчёлы из ME → Buffer
2. Buffer → Apiary (разведение)
3. Apiary → Buffer (результат)
4. Buffer → Analyzer (анализ стаками)
5. Analyzer → Buffer
6. Buffer → Acclimatizer (если нужно)
7. Acclimatizer → Buffer
8. Повтор 2-7 пока не достигнута цель
9. Buffer → ME (чистые) / Trash (гибриды)
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

- **OpenComputers Computer** с достаточной памятью
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

