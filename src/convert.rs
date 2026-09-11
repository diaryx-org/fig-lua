//! Lua values to and from [`fig::Value`], which is the JSON the helper wire
//! carries — so a script's tables are the wire's shapes, and the crate
//! converts rather than interprets.
//!
//! A Lua table with only the keys `1..n` is a sequence; any other table is
//! a map with its string keys (a non-string key is refused — the wire has
//! none). `nil` has no place in a table, so an absent field is an absent
//! JSON field, which every reader on the fig side treats as `null`.

use fig::Value;
use fig::language::LanguageError;
use mlua::{Lua, Table};

/// A Lua value as a `fig::Value`.
pub fn lua_to_value(v: &mlua::Value) -> Result<Value, LanguageError> {
    Ok(match v {
        mlua::Value::Nil => Value::Null,
        mlua::Value::Boolean(b) => Value::Bool(*b),
        mlua::Value::Integer(n) => Value::Int(*n),
        mlua::Value::Number(n) => Value::Float(*n),
        mlua::Value::String(s) => Value::Str(s.to_str().map_err(lua_err)?.to_string()),
        mlua::Value::Table(t) => table_to_value(t)?,
        // A function in the module table is the format's code, not its
        // description; it is left out rather than refused.
        mlua::Value::Function(_) => Value::Null,
        other => {
            return Err(LanguageError::new(format!(
                "a {} has no place in a node table or description",
                other.type_name()
            )));
        }
    })
}

fn table_to_value(t: &Table) -> Result<Value, LanguageError> {
    let len = t.raw_len();
    let mut entries = 0usize;
    let mut sequence = true;
    let mut map = Vec::new();
    for pair in t.clone().pairs::<mlua::Value, mlua::Value>() {
        let (k, v) = pair.map_err(lua_err)?;
        entries += 1;
        match &k {
            mlua::Value::Integer(i) if *i >= 1 && (*i as usize) <= len => {}
            mlua::Value::String(s) => {
                sequence = false;
                let value = lua_to_value(&v)?;
                if !matches!(value, Value::Null) {
                    map.push((Value::Str(s.to_str().map_err(lua_err)?.to_string()), value));
                }
            }
            other => {
                return Err(LanguageError::new(format!(
                    "a table key must be a string or a sequence index, not {}",
                    other.type_name()
                )));
            }
        }
    }
    if sequence && entries == len {
        let mut seq = Vec::with_capacity(len);
        for i in 1..=len {
            let v: mlua::Value = t.raw_get(i).map_err(lua_err)?;
            seq.push(lua_to_value(&v)?);
        }
        return Ok(Value::Seq(seq));
    }
    if sequence {
        return Err(LanguageError::new(
            "a table with integer keys that are not 1..n is neither a sequence nor a map",
        ));
    }
    if len > 0 {
        return Err(LanguageError::new(
            "a table mixes sequence indices and string keys",
        ));
    }
    Ok(Value::Map(map))
}

/// A `fig::Value` as a Lua value. `Null` becomes `nil`, so a null map entry
/// is an absent key.
pub fn value_to_lua(lua: &Lua, v: &Value) -> Result<mlua::Value, LanguageError> {
    Ok(match v {
        Value::Null => mlua::Value::Nil,
        Value::Bool(b) => mlua::Value::Boolean(*b),
        Value::Int(n) => mlua::Value::Integer(*n),
        Value::Uint(n) => match i64::try_from(*n) {
            Ok(i) => mlua::Value::Integer(i),
            Err(_) => mlua::Value::Number(*n as f64),
        },
        Value::Float(f) => mlua::Value::Number(*f),
        Value::Str(s) => mlua::Value::String(lua.create_string(s).map_err(lua_err)?),
        Value::Extended { text, .. } => {
            mlua::Value::String(lua.create_string(text).map_err(lua_err)?)
        }
        Value::Seq(items) => {
            let t = lua
                .create_table_with_capacity(items.len(), 0)
                .map_err(lua_err)?;
            for (i, item) in items.iter().enumerate() {
                t.raw_set(i + 1, value_to_lua(lua, item)?)
                    .map_err(lua_err)?;
            }
            mlua::Value::Table(t)
        }
        Value::Map(entries) => {
            let t = lua
                .create_table_with_capacity(0, entries.len())
                .map_err(lua_err)?;
            for (k, v) in entries {
                let key = match k {
                    Value::Str(s) => s.as_str(),
                    _ => continue,
                };
                let value = value_to_lua(lua, v)?;
                if !matches!(value, mlua::Value::Nil) {
                    t.raw_set(key, value).map_err(lua_err)?;
                }
            }
            mlua::Value::Table(t)
        }
    })
}

fn lua_err(e: mlua::Error) -> LanguageError {
    LanguageError::new(e.to_string())
}
