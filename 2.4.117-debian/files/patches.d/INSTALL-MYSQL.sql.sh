#!/bin/bash
F="INSTALL/MYSQL.sql"
T="INSTALL/MYSQL.sql.$$"
cp "${F}" "${T}"\
&& sed\
    -e 's/^[[:blank:]]*CREATE TABLE `/CREATE TABLE IF NOT EXISTS `/'\
    -e 's/^[[:blank:]]*INSERT INTO /INSERT IGNORE INTO /'\
    <"${T}" >"${F}"\
&& rm "${T}"
