#!/bin/bash

# Скрипт восстановления базы данных PostgreSQL на новом сервере

# Функция для вывода сообщений с цветом
function colored_echo() {
    local color=$1
    local message=$2
    case $color in
        "red") echo -e "\033[31m$message\033[0m" ;;
        "green") echo -e "\033[32m$message\033[0m" ;;
        "yellow") echo -e "\033[33m$message\033[0m" ;;
        "blue") echo -e "\033[34m$message\033[0m" ;;
        *) echo "$message" ;;
    esac
}

# Функция для проверки ввода пользователя
function prompt_input() {
    local prompt=$1
    local var_name=$2
    local is_password=$3
    local default_value=$4

    while true; do
        if [ "$is_password" = "y" ]; then
            # Убрали параметр -s для отображения пароля при вводе
            read -p "$prompt: " user_input
        else
            if [ -n "$default_value" ]; then
                read -p "$prompt (по умолчанию: $default_value): " user_input
                [ -z "$user_input" ] && user_input="$default_value"
            else
                read -p "$prompt: " user_input
            fi
        fi

        if [ -n "$user_input" ]; then
            eval "$var_name='$user_input'"
            break
        else
            colored_echo "red" "Ошибка: значение не может быть пустым"
        fi
    done
}

# Функция для подтверждения действия
function confirm_action() {
    local message=$1
    colored_echo "blue" "$message (y/n)"
    read -n 1 -r
    echo
    [[ $REPLY =~ ^[Yy]$ ]]
}

# Функция для запуска команд с sudo, если текущий пользователь не root
function run_as_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# Функция проверки наличия установленного PostgreSQL
function check_postgresql_installed() {
    if command -v psql &> /dev/null && dpkg -l | grep postgresql &> /dev/null; then
        return 0  # PostgreSQL установлен
    else
        return 1  # PostgreSQL не установлен
    fi
}

colored_echo "yellow" "\n=== Скрипт восстановления базы данных PostgreSQL ==="

# Проверка и создание директории для резервных копий
BACKUP_DIR="$HOME/backup"
if [ ! -d "$BACKUP_DIR" ]; then
    colored_echo "yellow" "Директория для резервных копий не найдена. Создаем $BACKUP_DIR..."
    mkdir -p "$BACKUP_DIR"
    colored_echo "green" "Директория $BACKUP_DIR успешно создана."
    colored_echo "yellow" "Пожалуйста, поместите файл резервной копии в директорию $BACKUP_DIR и запустите скрипт снова."
    exit 0
else
    # Получение списка файлов в директории бэкапа
    BACKUP_FILES=$(ls -1 "$BACKUP_DIR" 2>/dev/null)
    if [ -z "$BACKUP_FILES" ]; then
        colored_echo "red" "Директория $BACKUP_DIR пуста. Пожалуйста, поместите файл резервной копии в директорию и запустите скрипт снова."
        exit 0
    fi
    
    colored_echo "green" "Найдены следующие файлы резервных копий:"
    ls -1 "$BACKUP_DIR" | nl
fi

# Получение параметров от пользователя
colored_echo "blue" "\nВведите параметры для восстановления БД:"

prompt_input "Имя пользователя БД" DB_USER "n" "myuser"
prompt_input "Пароль пользователя БД" DB_PASSWORD "y" "1234"
prompt_input "Имя базы данных" DB_NAME "n" "dbname"
prompt_input "Имя файла резервной копии из списка выше" BACKUP_FILENAME "n"
prompt_input "Версия PostgreSQL" PG_VERSION "n" "16"
prompt_input "Порт PostgreSQL" PG_PORT "n" "5432"

# Формируем полный путь к файлу бекапа
BACKUP_FILE="$BACKUP_DIR/$BACKUP_FILENAME"

# Проверка существования файла бекапа
if [ ! -f "$BACKUP_FILE" ]; then
    colored_echo "red" "Ошибка: файл бекапа $BACKUP_FILE не найден"
    exit 1
fi

# Вывод сводки
colored_echo "green" "\n=== Параметры восстановления ==="
colored_echo "yellow" "Пользователь БД: $DB_USER"
colored_echo "yellow" "База данных: $DB_NAME"
colored_echo "yellow" "Файл бекапа: $BACKUP_FILE"
colored_echo "yellow" "Версия PostgreSQL: $PG_VERSION"
colored_echo "yellow" "Порт PostgreSQL: $PG_PORT\n"

if ! confirm_action "Продолжить с этими параметрами?"; then
    colored_echo "red" "Восстановление отменено пользователем"
    exit 0
fi

# Проверка наличия PostgreSQL и его установка при необходимости
if check_postgresql_installed; then
    colored_echo "green" "PostgreSQL уже установлен в системе"
else
    colored_echo "yellow" "PostgreSQL не обнаружен в системе"
    if confirm_action "Установить PostgreSQL $PG_VERSION?"; then
        colored_echo "yellow" "\nОбновление пакетов и установка PostgreSQL..."
        run_as_sudo apt update
        run_as_sudo apt install -y postgresql postgresql-contrib
        
        # Проверка успешности установки
        if [ $? -ne 0 ]; then
            colored_echo "red" "Ошибка при установке PostgreSQL"
            exit 1
        fi
    else
        colored_echo "red" "PostgreSQL необходим для восстановления базы данных"
        exit 1
    fi
fi

# Запуск службы PostgreSQL
colored_echo "yellow" "\nЗапуск PostgreSQL..."
run_as_sudo systemctl start postgresql
run_as_sudo systemctl enable postgresql

# Проверка статуса
PG_STATUS=$(systemctl is-active postgresql)
if [ "$PG_STATUS" != "active" ]; then
    colored_echo "red" "Ошибка: PostgreSQL не запущен. Статус: $PG_STATUS"
    exit 1
else
    colored_echo "green" "PostgreSQL успешно запущен. Статус: $PG_STATUS"
fi

# Создание пользователя и базы данных
colored_echo "yellow" "\nСоздание пользователя и базы данных..."
if sudo -u postgres psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='$DB_USER'" | grep -q 1; then
    colored_echo "yellow" "Пользователь $DB_USER уже существует, обновляем пароль..."
    sudo -u postgres psql -c "ALTER USER $DB_USER WITH PASSWORD '$DB_PASSWORD';"
else
    sudo -u postgres psql -c "CREATE USER $DB_USER WITH NOCREATEDB NOCREATEROLE NOSUPERUSER PASSWORD '$DB_PASSWORD';"
fi

# Проверка успешности создания пользователя
if [ $? -ne 0 ]; then
    colored_echo "red" "Ошибка при создании/обновлении пользователя БД"
    exit 1
fi

if sudo -u postgres psql -lqt | cut -d \| -f 1 | grep -qw "$DB_NAME"; then
    colored_echo "yellow" "База данных $DB_NAME уже существует"
    if confirm_action "Удалить существующую базу данных $DB_NAME и создать заново?"; then
        sudo -u postgres psql -c "DROP DATABASE $DB_NAME;"
        sudo -u postgres createdb "$DB_NAME" --owner="$DB_USER"
    fi
else
    sudo -u postgres createdb "$DB_NAME" --owner="$DB_USER"
fi

# Проверка успешности создания БД
if [ $? -ne 0 ]; then
    colored_echo "red" "Ошибка при создании базы данных"
    exit 1
fi

# Изменение метода аутентификации
colored_echo "yellow" "\nНастройка аутентификации..."
PG_HBA_FILE="/etc/postgresql/$PG_VERSION/main/pg_hba.conf"
if [ -f "$PG_HBA_FILE" ]; then
    if grep -q "local   all    all           peer" "$PG_HBA_FILE"; then
        run_as_sudo sed -i 's/local   all    all           peer/local   all    all           md5/' "$PG_HBA_FILE"
        colored_echo "green" "Файл $PG_HBA_FILE успешно изменен"
    else
        colored_echo "yellow" "Метод аутентификации уже настроен"
    fi
else
    colored_echo "red" "Ошибка: файл $PG_HBA_FILE не найден"
    exit 1
fi

# Перезагрузка PostgreSQL
colored_echo "yellow" "\nПерезагрузка PostgreSQL..."
run_as_sudo systemctl restart postgresql

# Восстановление базы данных из бекапа
colored_echo "yellow" "\nВосстановление базы данных из бекапа..."
if confirm_action "Выполнить восстановление базы $DB_NAME из файла $BACKUP_FILE?"; then
    colored_echo "yellow" "Процесс восстановления может занять некоторое время..."
    
    # Копируем файл резервной копии во временный каталог с правильными разрешениями
    colored_echo "yellow" "Копирование файла бекапа во временную директорию..."
    TMP_BACKUP="/tmp/$(basename "$BACKUP_FILE")"
    cp "$BACKUP_FILE" "$TMP_BACKUP"
    chmod 644 "$TMP_BACKUP"
    chown postgres:postgres "$TMP_BACKUP"
    
    # Проверяем тип файла (текстовый дамп или бинарный)
    if file "$TMP_BACKUP" | grep -q "text" || head -n 1 "$TMP_BACKUP" | grep -q "PostgreSQL database dump"; then
        # Текстовый дамп
        colored_echo "yellow" "Обнаружен текстовый дамп SQL, используем psql..."
        export PGPASSWORD="$DB_PASSWORD"
        sudo -u postgres psql -d "$DB_NAME" -f "$TMP_BACKUP" 2>/tmp/pg_restore_error.log
        restore_result=$?
    else
        # Бинарный дамп
        colored_echo "yellow" "Обнаружен бинарный дамп, используем pg_restore..."
        export PGPASSWORD="$DB_PASSWORD"
        sudo -u postgres pg_restore -d "$DB_NAME" "$TMP_BACKUP" 2>/tmp/pg_restore_error.log
        restore_result=$?
    fi
    
    # Удаляем временный файл
    rm -f "$TMP_BACKUP"

    if [ $restore_result -eq 0 ]; then
        colored_echo "green" "\nБаза данных успешно восстановлена из бекапа $BACKUP_FILE"
    else
        colored_echo "red" "\nОшибка при восстановлении базы данных"
        colored_echo "yellow" "Подробности ошибки можно посмотреть в файле /tmp/pg_restore_error.log"
        cat /tmp/pg_restore_error.log
        exit 1
    fi
fi

# Формируем URL для подключения к базе
PG_HOST="localhost"
DATABASE_URL="postgresql://$DB_USER:$DB_PASSWORD@$PG_HOST:$PG_PORT/$DB_NAME"

colored_echo "green" "\n=== Процесс завершен успешно ==="
colored_echo "yellow" "Данные для подключения к базе данных:"
colored_echo "green" "DB_NAME = \"$DB_NAME\" # Имя базы данных"
colored_echo "green" "DB_USER = \"$DB_USER\" # Логин пользователя"
colored_echo "green" "DB_PASSWORD = \"$DB_PASSWORD\" # Пароль пользователя"
colored_echo "green" "PG_HOST = \"$PG_HOST\"  # Адрес сервера postgresql"
colored_echo "green" "PG_PORT = \"$PG_PORT\"  # Порт сервера postgresql"
colored_echo "green" "DATABASE_URL = \"$DATABASE_URL\""
