module suiroll::suiroll {
  use std::vector;
  use sui::object::{Self, UID, ID};
  use sui::coin::{Self, Coin};
  use sui::tx_context::{TxContext, sender};
  use sui::transfer::{transfer, public_transfer, share_object};
  use sui::balance::{Self, Balance};
  use sui::table::{Self, Table};
  use sui::clock::{Self, Clock};
  use sui::ecvrf::{ecvrf_verify};
  use sui::hex::{Self};
  use sui::hash::{blake2b256};
  use sui::event::emit;

  // Constants

  /// This is how long (1 days in milliseconds) should pass for the user to get a refund if server doesn't submit the result
  const REFUND_AFTER: u64 = 120000;
  const BASIS_POINTS: u64 = 10_000;

  // Errors
  const E_INVALID_SELECTION: u64 = 0;
  const E_INVALID_PLAY_AMOUNT: u64 = 1;
  const E_LOW_HOUSE_BALANCE: u64 = 2;
  const E_EARLY_REFUND: u64 = 3;
  const E_INVALID_PROOF: u64 = 4;
  const E_SEED_USED: u64 = 5;
  const E_RESULT_SUBMITTED: u64 = 6;

  /// Capability allowing the bearer to execute admin related tasks
  struct AdminCap has key {id: UID}

  struct Config has key {
    id: UID,
    /// Makes sure that user cannot use the same seed which would result in predicatble random number
    used_seeds: Table<vector<u8>, bool>,
    /// The public key of the VRF keypair that will be creating random outputs
    vrf_pubkey: vector<u8>,
  }

  struct House<phantom COIN> has key {
    id: UID,
    /// The total balance available in the house
    balance: Balance<COIN>,
    /// The accumulated fees
    fees: Balance<COIN>,
    /// The address that will be receiving the funds from the games
    treasury: address,
    /// 10,000 basis points fees that will be collected on every user win
    fee_bp: u64,
    /// Min amount of stake one can play
    min_stake: u64,
    /// Max amount of stake one can play
    max_stake: u64,
  }

  struct Game<phantom COIN> has key {
    id: UID,
    /// The player of the game
    player: address,
    /// The total stake this game is played for. This includes user's amount + equal amount from the house
    /// If user wins he takes the full stake, otherwise it goes back to the house
    stake: Balance<COIN>,
    /// The user selected random seeds (UUID) that will be used to create the random VRF outputs
    seeds: vector<vector<u8>>,
    /// 0 for Even nad 1 for Odd
    user_selection: u8,
    /// The clock time when the game was created
    start_ts: u64,
    /// Indicated is the result for this game has been submitted
    result_submitted: bool,
    /// First random number
    random_1: u8,
    /// Second random number
    random_2: u8,
  }

  // Events
  struct ConfigUpdated has copy, drop {
    vrf_pubkey: vector<u8>,
  }
  
  struct HouseDataUpdated has copy, drop {
    treasury: address,
    fee_bp: u64,
    min_stake: u64,
    max_stake: u64,
  }

  struct GameCreated has copy, drop {
    id: ID,
    stake: u64,
    player: address,
    seeds: vector<vector<u8>>,
    user_selection: u8,
    start_ts: u64,
  }

  /// Module initializer to be executed when this module is published by the the Sui runtime
  fun init(ctx: &mut TxContext) {
    let admin_cap = AdminCap {
      id: object::new(ctx),
    };

    transfer(admin_cap, sender(ctx));
  }

  #[view]
  public fun house_balance<COIN>(house: &House<COIN>): u64 {
    balance::value(&house.balance)
  }

  #[view]
  public fun house_fees<COIN>(house: &House<COIN>): u64 {
    balance::value(&house.fees)
  }

  #[view]
  public fun stake<COIN>(game: &Game<COIN>): u64 {
    balance::value(&game.stake)
  }

  /// Initialized the global config
  /// 
  /// # Auth
  /// - Only bearer of the AdminCap is allowed to call this function
  public entry fun init_config(
    _cap: &AdminCap,
    vrf_pubkey: vector<u8>,
    ctx: &mut TxContext
  ) {
    let vrf_pubkey = hex::decode(vrf_pubkey);
    
    let config = Config {
      id: object::new(ctx),
      vrf_pubkey,
      used_seeds: table::new(ctx),
    };

    share_object(config);
  }

  /// Inits the house data
  /// 
  /// # Auth
  /// - Only bearer of the AdminCap is allowed to call this function
  public entry fun init_house<COIN>(
    _cap: &AdminCap,
    treasury: address,
    coin: Coin<COIN>,
    fee_bp: u64,
    min_stake: u64,
    max_stake: u64,
    ctx: &mut TxContext
  ) {
    let house = House<COIN> {
      id: object::new(ctx),
      treasury,
      fees: balance::zero(),
      balance: coin::into_balance(coin),
      fee_bp,
      min_stake,
      max_stake,
    };

    share_object(house);
  }

  /// Updates the global config
  /// 
  /// # Auth
  /// - Only bearer of the AdminCap is allowed to call this function
  public entry fun update_config<COIN>(
    _cap: &AdminCap,
    config: &mut Config,
    vrf_pubkey: vector<u8>,
  ) {
    let vrf_pubkey = hex::decode(vrf_pubkey);
    config.vrf_pubkey = vrf_pubkey;

    emit(ConfigUpdated {vrf_pubkey});
  }

  /// Updates the house data
  /// 
  /// # Auth
  /// - Only bearer of the AdminCap is allowed to call this function
  public entry fun update_house_data<COIN>(
    _cap: &AdminCap,
    house: &mut House<COIN>,
    treasury: address,
    fee_bp: u64,
    min_stake: u64,
    max_stake: u64,
  ) {
    house.treasury = treasury;
    house.fee_bp = fee_bp;
    house.min_stake = min_stake;
    house.max_stake = max_stake;

    emit(HouseDataUpdated {
      treasury,
      fee_bp,
      min_stake,
      max_stake,
    });
  }

  /// Adds additional funds to the house
  public entry fun fund_house<COIN>(house: &mut House<COIN>, coin: Coin<COIN>) {        
    let balance = coin::into_balance(coin);
    balance::join(&mut house.balance, balance);
  }

  /// Withdraws the given amount of coins from the house balance
  /// 
  /// # Auth
  /// - Only bearer of the AdminCap is allowed to call this function
  public entry fun withdraw_funds<COIN>(
    _cap: &AdminCap,
    house: &mut House<COIN>,
    amount: u64,
    ctx: &mut TxContext
  ) {
    let coin = coin::take(&mut house.balance, amount, ctx);
    public_transfer(coin, house.treasury);
  }

  /// Withdraws accumulated fees
  /// 
  /// # Auth
  /// - Only bearer of the AdminCap is allowed to call this function/// 
  public entry fun withdraw_fees<COIN>(
    _cap: &AdminCap,
    house: &mut House<COIN>,
    ctx: &mut TxContext
  ) {
    let fees = house_fees(house);
    let coin = coin::take(&mut house.fees, fees, ctx);

    public_transfer(coin, house.treasury);
  }

  /// This will check if a user provided seed has been alrady used. Same seeds produce
  /// same random VRF output, thus we cannot allow users to use the same seed more than once
  fun check_seeds(config: &mut Config, seeds: &vector<vector<u8>>,) {
    let len = vector::length(seeds);
    let i = 0;

    while(i < len) {
      let seed = *vector::borrow(seeds, i);
      assert!(!table::contains(&config.used_seeds, seed), E_SEED_USED);
      table::add(&mut config.used_seeds, seed, true);

      i = i + 1;
    }
  }

  /// Allows anyone to play the game
  public entry fun play<COIN>(
    config: &mut Config,
    house: &mut House<COIN>,
    seeds: vector<vector<u8>>,
    user_selection: u8,
    coin: Coin<COIN>,
    clock: &Clock,
    ctx: &mut TxContext,
  ) {
    check_seeds(config, &seeds);

    assert!(user_selection <= 1, E_INVALID_SELECTION);
    let play_amount = coin::value(&coin);
    assert!(play_amount >= house.min_stake && play_amount <= house.max_stake, E_INVALID_PLAY_AMOUNT);

    // Does house has enough funds to insure this game>
    assert!(house_balance(house) >= play_amount, E_LOW_HOUSE_BALANCE);

    // get house and players stake and add them together to create the games total stake
    let user_stake = coin::into_balance(coin);
    let house_stake = balance::split(&mut house.balance, play_amount);
    balance::join(&mut user_stake, house_stake);
    
    let start_ts = clock::timestamp_ms(clock);
    let game = Game {
      id: object::new(ctx),
      player: sender(ctx),
      stake: user_stake,
      seeds,
      user_selection,
      start_ts,
      result_submitted: false,
      random_1: 0,
      random_2: 0,
    };

    emit(GameCreated {
      id: object::uid_to_inner(&game.id),
      player: sender(ctx),
      stake: balance::value(&game.stake),
      seeds,
      user_selection,
      start_ts
    });

    share_object(game);
  }

  /// Verifies the random VRF output and makes sure it was created using the private key corresponding to the
  /// vrf_pubkey and the seed (which was provided by the user). The function will use this random output to
  /// get a random number in the range [1, 6]
  fun verify_and_get_random_number(
    config: &Config,
    seed: vector<u8>,
    random_output: vector<u8>,
    proof: vector<u8>,
  ): u8 {
    assert!(ecvrf_verify(&random_output, &seed, &config.vrf_pubkey, &proof), E_INVALID_PROOF);
    let hashed_output = blake2b256(&random_output);
    let first_byte = vector::borrow(&hashed_output, 0);
    // A dice has 6 numbers so we want the first byte to be in the range [1, 6]
    let random_number = (*first_byte % 6) + 1;

    random_number
  }

  /// The API will reveal the result of the game. Note this function can be called by anyone who possesses the
  /// below parameters. Checks will be made to ensure that VRF proofs and outputs are created only by the bearer
  /// of the vrf_public key
  public entry fun reveal_result<COIN>(
    config: &Config,
    house: &mut House<COIN>,
    game: &mut Game<COIN>,
    random_outputs: vector<vector<u8>>,
    proofs: vector<vector<u8>>,
    ctx: &mut TxContext,
  ) {
    assert!(!game.result_submitted, E_RESULT_SUBMITTED);
    game.result_submitted = true;

    let random_1 = verify_and_get_random_number(
      config,
      *vector::borrow(&game.seeds, 0),
      *vector::borrow(&random_outputs, 0),
      *vector::borrow(&proofs, 0),
    );
    let random_2 = verify_and_get_random_number(
      config,
      *vector::borrow(&game.seeds, 1),
      *vector::borrow(&random_outputs, 1),
      *vector::borrow(&proofs, 1),
    );

    game.random_1 = random_1;
    game.random_2 = random_2;

    let result = (random_1 + random_2) % 2;
    let user_wins = game.user_selection == result;

    if(user_wins) {
      let game_stake = balance::value(&game.stake);
      let fee_amount = (game_stake * house.fee_bp) / BASIS_POINTS;
      let fees = balance::split(&mut game.stake, fee_amount);

      // add fees to house balance
      balance::join(&mut house.fees, fees);

      // transfer funds to the player
      let reward = stake(game);
      let coin = coin::take(&mut game.stake, reward, ctx);
      public_transfer(coin, game.player);
    } else {
      // Returns the game stake back to the house balance
      balance::join(&mut house.balance, balance::withdraw_all(&mut game.stake));
    }
  }

  /// Allows the game player to get his initial funds back if the Game server does not reveal the game result.
  /// This is a protection against server acting as an edversary. User can get a refund for his game after a
  /// predefined period of time (which is a constant value)
  public entry fun refund<COIN>(
    game: &mut Game<COIN>,
    house: &mut House<COIN>,
    clock: &Clock,
    ctx: &mut TxContext,
  ) {
    let now = clock::timestamp_ms(clock);
    assert!(now - game.start_ts >= REFUND_AFTER, E_EARLY_REFUND);

    let half_stake = stake(game) / 2;

    // Transfer to the user
    let user_coin = coin::take(&mut game.stake, half_stake, ctx);
    public_transfer(user_coin, game.player);

    // Update the house balance
    let house_stake = balance::withdraw_all(&mut game.stake);
    balance::join(&mut house.balance, house_stake);
  }
}
