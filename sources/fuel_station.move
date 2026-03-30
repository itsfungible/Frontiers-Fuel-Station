module fuel_station::fuel_station;

use fuel_station::config::{Self, AdminCap, FuelStationConfig};
use sui::{
    balance::{Self, Balance},
    clock::Clock,
    coin::{Self, Coin},
    event,
    sui::SUI,
    transfer,
};
use world::{access::OwnerCap, character::Character, storage_unit::StorageUnit};

#[error(code = 0)]
const ENotOwner: vector<u8> = b"Not the station owner";
#[error(code = 1)]
const EStationNotFound: vector<u8> = b"Station not found";
#[error(code = 2)]
const EInvalidQuantity: vector<u8> = b"Quantity must be greater than 0";
#[error(code = 3)]
const EInsufficientEscrow: vector<u8> = b"Insufficient escrow balance for payout";
#[error(code = 4)]
const EStationPaused: vector<u8> = b"Station is paused";
#[error(code = 5)]
const EInvalidCut: vector<u8> = b"Operator cut must be 0-95";
#[error(code = 6)]
const EInvalidPrice: vector<u8> = b"Price per unit must be > 0";
#[error(code = 7)]
const EInsufficientPayment: vector<u8> = b"Insufficient SUI payment";
#[error(code = 8)]
const EStationAlreadyExists: vector<u8> = b"Station already exists for this SSU";
#[error(code = 9)]
const EFuelConfigNotFound: vector<u8> = b"Fuel config not found for this station";
#[error(code = 10)]
const EFuelAlreadyConfigured: vector<u8> = b"Fuel already configured for this station";

const MAX_OPERATOR_CUT: u8 = 95;
const WINDOW_DURATION_MS: u64 = 3_600_000; // 1 hour

public struct StationKey has copy, drop, store {
    storage_unit_id: ID,
}

public struct FuelKey has copy, drop, store {
    storage_unit_id: ID,
    fuel_type_id: u64,
}

public struct Station has store {
    owner: address,
    operator_cut: u8,
    owner_revenue: Balance<SUI>,
    active: bool,
    created_at_ms: u64,
    fuel_type_ids: vector<u64>,
}

public struct FuelConfig has store {
    price_per_unit: u64,
    escrow: Balance<SUI>,
    window_revenue: u64,
    window_fuel_sold: u64,
    window_start_ms: u64,
    window_deliveries: u64,
    total_revenue: u64,
    total_fuel_sold: u64,
    total_fuel_delivered: u64,
    total_paid_runners: u64,
}

// === Events ===

public struct StationCreatedEvent has copy, drop {
    storage_unit_id: ID,
    owner: address,
    operator_cut: u8,
}

public struct FuelConfiguredEvent has copy, drop {
    storage_unit_id: ID,
    fuel_type_id: u64,
    price_per_unit: u64,
}

public struct FuelPurchasedEvent has copy, drop {
    storage_unit_id: ID,
    buyer: address,
    fuel_type_id: u64,
    quantity: u64,
    total_paid: u64,
}

public struct FuelDeliveredEvent has copy, drop {
    storage_unit_id: ID,
    runner: address,
    fuel_type_id: u64,
    quantity: u64,
    payout: u64,
}

public struct FuelSoldEvent has copy, drop {
    storage_unit_id: ID,
    seller: address,
    fuel_type_id: u64,
    quantity: u64,
    sui_received: u64,
}

public struct StationFundedEvent has copy, drop {
    storage_unit_id: ID,
    fuel_type_id: u64,
    amount: u64,
}

public struct OwnerWithdrawEvent has copy, drop {
    storage_unit_id: ID,
    amount: u64,
}

public struct StationClosedEvent has copy, drop {
    storage_unit_id: ID,
}

// === Create Station ===

public fun create_station(
    cfg: &mut FuelStationConfig,
    admin_cap: &AdminCap,
    storage_unit_id: ID,
    operator_cut: u8,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let key = StationKey { storage_unit_id };
    assert!(!config::has_field(cfg, key), EStationAlreadyExists);
    assert!(operator_cut <= MAX_OPERATOR_CUT, EInvalidCut);

    let station = Station {
        owner: ctx.sender(),
        operator_cut,
        owner_revenue: balance::zero(),
        active: true,
        created_at_ms: clock.timestamp_ms(),
        fuel_type_ids: vector[],
    };

    config::add_field(cfg, admin_cap, key, station);

    event::emit(StationCreatedEvent {
        storage_unit_id,
        owner: ctx.sender(),
        operator_cut,
    });
}

public fun configure_fuel(
    cfg: &mut FuelStationConfig,
    admin_cap: &AdminCap,
    storage_unit_id: ID,
    fuel_type_id: u64,
    price_per_unit: u64,
    clock: &Clock,
    ctx: &TxContext,
) {
    assert!(price_per_unit > 0, EInvalidPrice);

    let station_key = StationKey { storage_unit_id };
    assert!(config::has_field(cfg, station_key), EStationNotFound);

    let fuel_key = FuelKey { storage_unit_id, fuel_type_id };
    assert!(!config::has_field(cfg, fuel_key), EFuelAlreadyConfigured);

    let mut station = config::remove_field<StationKey, Station>(cfg, admin_cap, station_key);
    assert!(station.owner == ctx.sender(), ENotOwner);
    vector::push_back(&mut station.fuel_type_ids, fuel_type_id);
    config::add_field(cfg, admin_cap, station_key, station);

    let fuel = FuelConfig {
        price_per_unit,
        escrow: balance::zero(),
        window_revenue: 0,
        window_fuel_sold: 0,
        window_start_ms: clock.timestamp_ms(),
        window_deliveries: 0,
        total_revenue: 0,
        total_fuel_sold: 0,
        total_fuel_delivered: 0,
        total_paid_runners: 0,
    };

    config::add_field(cfg, admin_cap, fuel_key, fuel);

    event::emit(FuelConfiguredEvent {
        storage_unit_id,
        fuel_type_id,
        price_per_unit,
    });
}

// === Buy Fuel ===
public fun buy_fuel<T: key>(
    cfg: &mut FuelStationConfig,
    admin_cap: &AdminCap,
    storage_unit: &mut StorageUnit,
    character: &Character,
    _owner_cap: &OwnerCap<T>,
    storage_unit_id: ID,
    fuel_type_id: u64,
    quantity: u64,
    payment: Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(quantity > 0, EInvalidQuantity);

    let station_key = StationKey { storage_unit_id };
    assert!(config::has_field(cfg, station_key), EStationNotFound);
    let fuel_key = FuelKey { storage_unit_id, fuel_type_id };
    assert!(config::has_field(cfg, fuel_key), EFuelConfigNotFound);

    let station = config::borrow_field<StationKey, Station>(cfg, station_key);
    assert!(station.active, EStationPaused);
    let operator_cut = station.operator_cut;

    let fuel = config::borrow_field_mut<FuelKey, FuelConfig>(cfg, admin_cap, fuel_key);
    let total_cost = fuel.price_per_unit * quantity;
    assert!(coin::value(&payment) >= total_cost, EInsufficientPayment);

    let mut pay_balance = coin::into_balance(payment);
    if (balance::value(&pay_balance) > total_cost) {
        let change_amount = balance::value(&pay_balance) - total_cost;
        let change = balance::split(&mut pay_balance, change_amount);
        transfer::public_transfer(coin::from_balance(change, ctx), ctx.sender());
    };

    let owner_amount = total_cost * (operator_cut as u64) / 100;
    let owner_share = if (owner_amount > 0) {
        balance::split(&mut pay_balance, owner_amount)
    } else {
        balance::zero()
    };

    balance::join(&mut fuel.escrow, pay_balance);

    maybe_roll_window(fuel, clock);
    fuel.window_revenue = fuel.window_revenue + total_cost;
    fuel.window_fuel_sold = fuel.window_fuel_sold + quantity;
    fuel.total_revenue = fuel.total_revenue + total_cost;
    fuel.total_fuel_sold = fuel.total_fuel_sold + quantity;

    let station = config::borrow_field_mut<StationKey, Station>(cfg, admin_cap, station_key);
    balance::join(&mut station.owner_revenue, owner_share);

    let fuel_items = storage_unit.withdraw_from_open_inventory(
        character,
        config::fuel_station_auth(),
        fuel_type_id,
        (quantity as u32),
        ctx,
    );
    storage_unit.deposit_to_owned(
        character,
        fuel_items,
        config::fuel_station_auth(),
        ctx,
    );

    event::emit(FuelPurchasedEvent {
        storage_unit_id,
        buyer: ctx.sender(),
        fuel_type_id,
        quantity,
        total_paid: total_cost,
    });
}

// === Deliver Fuel ===
public fun deliver_fuel<T: key>(
    cfg: &mut FuelStationConfig,
    admin_cap: &AdminCap,
    storage_unit: &mut StorageUnit,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    storage_unit_id: ID,
    fuel_type_id: u64,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(quantity > 0, EInvalidQuantity);

    let station_key = StationKey { storage_unit_id };
    assert!(config::has_field(cfg, station_key), EStationNotFound);
    let fuel_key = FuelKey { storage_unit_id, fuel_type_id };
    assert!(config::has_field(cfg, fuel_key), EFuelConfigNotFound);

    let station = config::borrow_field<StationKey, Station>(cfg, station_key);
    assert!(station.active, EStationPaused);
    let operator_cut = station.operator_cut;

    let fuel = config::borrow_field_mut<FuelKey, FuelConfig>(cfg, admin_cap, fuel_key);
    maybe_roll_window(fuel, clock);

    let payout = compute_payout(operator_cut, fuel, quantity);
    assert!(balance::value(&fuel.escrow) >= payout, EInsufficientEscrow);

    let fuel_items = storage_unit.withdraw_by_owner<T>(
        character,
        owner_cap,
        fuel_type_id,
        (quantity as u32),
        ctx,
    );
    storage_unit.deposit_to_open_inventory(
        character,
        fuel_items,
        config::fuel_station_auth(),
        ctx,
    );

    let payout_balance = balance::split(&mut fuel.escrow, payout);
    transfer::public_transfer(coin::from_balance(payout_balance, ctx), ctx.sender());

    fuel.window_deliveries = fuel.window_deliveries + quantity;
    fuel.total_fuel_delivered = fuel.total_fuel_delivered + quantity;
    fuel.total_paid_runners = fuel.total_paid_runners + payout;

    event::emit(FuelDeliveredEvent {
        storage_unit_id,
        runner: ctx.sender(),
        fuel_type_id,
        quantity,
        payout,
    });
}

// === Sell Fuel (player sells owned fuel to station, receives SUI) ===
public fun sell_fuel<T: key>(
    cfg: &mut FuelStationConfig,
    admin_cap: &AdminCap,
    storage_unit: &mut StorageUnit,
    character: &Character,
    owner_cap: &OwnerCap<T>,
    storage_unit_id: ID,
    fuel_type_id: u64,
    quantity: u64,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    assert!(quantity > 0, EInvalidQuantity);

    let station_key = StationKey { storage_unit_id };
    assert!(config::has_field(cfg, station_key), EStationNotFound);
    let fuel_key = FuelKey { storage_unit_id, fuel_type_id };
    assert!(config::has_field(cfg, fuel_key), EFuelConfigNotFound);

    let station = config::borrow_field<StationKey, Station>(cfg, station_key);
    assert!(station.active, EStationPaused);
    let operator_cut = station.operator_cut;

    let fuel = config::borrow_field_mut<FuelKey, FuelConfig>(cfg, admin_cap, fuel_key);
    maybe_roll_window(fuel, clock);

    let payout = compute_payout(operator_cut, fuel, quantity);
    assert!(balance::value(&fuel.escrow) >= payout, EInsufficientEscrow);

    let fuel_items = storage_unit.withdraw_by_owner<T>(
        character,
        owner_cap,
        fuel_type_id,
        (quantity as u32),
        ctx,
    );
    storage_unit.deposit_to_open_inventory(
        character,
        fuel_items,
        config::fuel_station_auth(),
        ctx,
    );

    let payout_balance = balance::split(&mut fuel.escrow, payout);
    transfer::public_transfer(coin::from_balance(payout_balance, ctx), ctx.sender());

    fuel.window_deliveries = fuel.window_deliveries + quantity;
    fuel.total_fuel_delivered = fuel.total_fuel_delivered + quantity;
    fuel.total_paid_runners = fuel.total_paid_runners + payout;

    event::emit(FuelSoldEvent {
        storage_unit_id,
        seller: ctx.sender(),
        fuel_type_id,
        quantity,
        sui_received: payout,
    });
}

// === Fund Station / Fuel Pool ===
public fun fund_station(
    cfg: &mut FuelStationConfig,
    admin_cap: &AdminCap,
    storage_unit_id: ID,
    fuel_type_id: u64,
    payment: Coin<SUI>,
) {
    let station_key = StationKey { storage_unit_id };
    assert!(config::has_field(cfg, station_key), EStationNotFound);
    let fuel_key = FuelKey { storage_unit_id, fuel_type_id };
    assert!(config::has_field(cfg, fuel_key), EFuelConfigNotFound);

    let amount = coin::value(&payment);
    let fuel = config::borrow_field_mut<FuelKey, FuelConfig>(cfg, admin_cap, fuel_key);
    balance::join(&mut fuel.escrow, coin::into_balance(payment));

    event::emit(StationFundedEvent { storage_unit_id, fuel_type_id, amount });
}

public fun withdraw_revenue(
    cfg: &mut FuelStationConfig,
    admin_cap: &AdminCap,
    storage_unit_id: ID,
    ctx: &mut TxContext,
) {
    let station_key = StationKey { storage_unit_id };
    assert!(config::has_field(cfg, station_key), EStationNotFound);

    let station = config::borrow_field_mut<StationKey, Station>(cfg, admin_cap, station_key);
    assert!(station.owner == ctx.sender(), ENotOwner);

    let amount = balance::value(&station.owner_revenue);
    if (amount > 0) {
        let revenue = balance::withdraw_all(&mut station.owner_revenue);
        transfer::public_transfer(coin::from_balance(revenue, ctx), ctx.sender());
    };

    event::emit(OwnerWithdrawEvent { storage_unit_id, amount });
}

public fun set_price(
    cfg: &mut FuelStationConfig,
    admin_cap: &AdminCap,
    storage_unit_id: ID,
    fuel_type_id: u64,
    new_price: u64,
    ctx: &TxContext,
) {
    assert!(new_price > 0, EInvalidPrice);

    let station_key = StationKey { storage_unit_id };
    assert!(config::has_field(cfg, station_key), EStationNotFound);
    let fuel_key = FuelKey { storage_unit_id, fuel_type_id };
    assert!(config::has_field(cfg, fuel_key), EFuelConfigNotFound);

    let station = config::borrow_field<StationKey, Station>(cfg, station_key);
    assert!(station.owner == ctx.sender(), ENotOwner);

    let fuel = config::borrow_field_mut<FuelKey, FuelConfig>(cfg, admin_cap, fuel_key);
    fuel.price_per_unit = new_price;
}

public fun set_operator_cut(
    cfg: &mut FuelStationConfig,
    admin_cap: &AdminCap,
    storage_unit_id: ID,
    new_cut: u8,
    ctx: &TxContext,
) {
    assert!(new_cut <= MAX_OPERATOR_CUT, EInvalidCut);
    let station_key = StationKey { storage_unit_id };
    assert!(config::has_field(cfg, station_key), EStationNotFound);
    let station = config::borrow_field_mut<StationKey, Station>(cfg, admin_cap, station_key);
    assert!(station.owner == ctx.sender(), ENotOwner);
    station.operator_cut = new_cut;
}

public fun toggle_active(
    cfg: &mut FuelStationConfig,
    admin_cap: &AdminCap,
    storage_unit_id: ID,
    ctx: &TxContext,
) {
    let station_key = StationKey { storage_unit_id };
    assert!(config::has_field(cfg, station_key), EStationNotFound);
    let station = config::borrow_field_mut<StationKey, Station>(cfg, admin_cap, station_key);
    assert!(station.owner == ctx.sender(), ENotOwner);
    station.active = !station.active;
}

public fun close_station(
    cfg: &mut FuelStationConfig,
    admin_cap: &AdminCap,
    storage_unit_id: ID,
    ctx: &mut TxContext,
) {
    let station_key = StationKey { storage_unit_id };
    assert!(config::has_field(cfg, station_key), EStationNotFound);

    let Station {
        owner,
        operator_cut: _,
        owner_revenue,
        active: _,
        created_at_ms: _,
        fuel_type_ids,
    } = config::remove_field<StationKey, Station>(cfg, admin_cap, station_key);
    assert!(owner == ctx.sender(), ENotOwner);

    let mut i = 0;
    let len = vector::length(&fuel_type_ids);
    while (i < len) {
        let fuel_type_id = *vector::borrow(&fuel_type_ids, i);
        let fuel_key = FuelKey { storage_unit_id, fuel_type_id };
        if (config::has_field(cfg, fuel_key)) {
            let FuelConfig {
                price_per_unit: _,
                escrow,
                window_revenue: _,
                window_fuel_sold: _,
                window_start_ms: _,
                window_deliveries: _,
                total_revenue: _,
                total_fuel_sold: _,
                total_fuel_delivered: _,
                total_paid_runners: _,
            } = config::remove_field<FuelKey, FuelConfig>(cfg, admin_cap, fuel_key);
            transfer::public_transfer(coin::from_balance(escrow, ctx), owner);
        };
        i = i + 1;
    };

    transfer::public_transfer(coin::from_balance(owner_revenue, ctx), owner);

    event::emit(StationClosedEvent { storage_unit_id });
}

// === Views ===

public fun station_info(cfg: &FuelStationConfig, storage_unit_id: ID): (address, u8, u64, bool, u64) {
    let station_key = StationKey { storage_unit_id };
    let s = config::borrow_field<StationKey, Station>(cfg, station_key);
    (
        s.owner,
        s.operator_cut,
        balance::value(&s.owner_revenue),
        s.active,
        s.created_at_ms,
    )
}

public fun station_fuel_count(cfg: &FuelStationConfig, storage_unit_id: ID): u64 {
    let station_key = StationKey { storage_unit_id };
    let s = config::borrow_field<StationKey, Station>(cfg, station_key);
    vector::length(&s.fuel_type_ids)
}

public fun station_fuel_at(cfg: &FuelStationConfig, storage_unit_id: ID, index: u64): u64 {
    let station_key = StationKey { storage_unit_id };
    let s = config::borrow_field<StationKey, Station>(cfg, station_key);
    *vector::borrow(&s.fuel_type_ids, index)
}

public fun fuel_info(cfg: &FuelStationConfig, storage_unit_id: ID, fuel_type_id: u64): (u64, u64, u64, u64, u64, u64, u64, u64) {
    let fuel_key = FuelKey { storage_unit_id, fuel_type_id };
    let f = config::borrow_field<FuelKey, FuelConfig>(cfg, fuel_key);
    (
        f.price_per_unit,
        balance::value(&f.escrow),
        f.window_revenue,
        f.window_fuel_sold,
        f.total_revenue,
        f.total_fuel_sold,
        f.total_fuel_delivered,
        f.total_paid_runners,
    )
}

public fun current_payout_rate(cfg: &FuelStationConfig, storage_unit_id: ID, fuel_type_id: u64): u64 {
    let station_key = StationKey { storage_unit_id };
    let fuel_key = FuelKey { storage_unit_id, fuel_type_id };
    let s = config::borrow_field<StationKey, Station>(cfg, station_key);
    let f = config::borrow_field<FuelKey, FuelConfig>(cfg, fuel_key);
    compute_payout(s.operator_cut, f, 1)
}

// === Internal ===

fun compute_payout(operator_cut: u8, fuel: &FuelConfig, quantity: u64): u64 {
    let escrow_val = balance::value(&fuel.escrow);
    if (escrow_val == 0 || fuel.window_fuel_sold == 0) {
        return 0
    };

    let runner_share_pct = 100 - (operator_cut as u64);
    let pool = fuel.window_revenue * runner_share_pct / 100;
    let payout_per_unit = if (fuel.window_fuel_sold > 0) {
        pool / fuel.window_fuel_sold
    } else {
        0
    };

    let total_payout = payout_per_unit * quantity;
    let max_payout = escrow_val / 2;
    if (total_payout > max_payout) {
        max_payout
    } else {
        total_payout
    }
}

fun maybe_roll_window(fuel: &mut FuelConfig, clock: &Clock) {
    let now = clock.timestamp_ms();
    if (now >= fuel.window_start_ms + WINDOW_DURATION_MS) {
        fuel.window_revenue = 0;
        fuel.window_fuel_sold = 0;
        fuel.window_deliveries = 0;
        fuel.window_start_ms = now;
    };
}
