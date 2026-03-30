module fuel_station::config;

use sui::dynamic_field as df;

public struct FuelStationConfig has key {
    id: UID,
}

public struct AdminCap has key, store {
    id: UID,
}

public struct FuelStationAuth has drop {}

public fun fuel_station_auth(): FuelStationAuth {
    FuelStationAuth {}
}

fun init(ctx: &mut TxContext) {
    let admin_cap = AdminCap { id: object::new(ctx) };
    transfer::transfer(admin_cap, ctx.sender());

    let config = FuelStationConfig { id: object::new(ctx) };
    transfer::share_object(config);
}

public fun has_field<K: copy + drop + store>(config: &FuelStationConfig, key: K): bool {
    df::exists_(&config.id, key)
}

public fun borrow_field<K: copy + drop + store, V: store>(config: &FuelStationConfig, key: K): &V {
    df::borrow(&config.id, key)
}

public fun borrow_field_mut<K: copy + drop + store, V: store>(
    config: &mut FuelStationConfig,
    _: &AdminCap,
    key: K,
): &mut V {
    df::borrow_mut(&mut config.id, key)
}

public fun add_field<K: copy + drop + store, V: store>(
    config: &mut FuelStationConfig,
    _: &AdminCap,
    key: K,
    value: V,
) {
    df::add(&mut config.id, key, value);
}

public fun set_field<K: copy + drop + store, V: store + drop>(
    config: &mut FuelStationConfig,
    _: &AdminCap,
    key: K,
    value: V,
) {
    if (df::exists_(&config.id, copy key)) {
        let _old: V = df::remove(&mut config.id, copy key);
    };
    df::add(&mut config.id, key, value);
}

public fun remove_field<K: copy + drop + store, V: store>(
    config: &mut FuelStationConfig,
    _: &AdminCap,
    key: K,
): V {
    df::remove(&mut config.id, key)
}
