//! RFC-0026: bounded Devnet-only registration. No login, transfer or recovery override.
use solana_program::{
    account_info::AccountInfo, entrypoint::ProgramResult, program::invoke, program::invoke_signed,
    program_error::ProgramError, pubkey::Pubkey, rent::Rent, sysvar::Sysvar,
};
use solana_system_interface::instruction as system_instruction;

#[cfg(not(feature = "no-entrypoint"))]
solana_program::entrypoint!(process_instruction);

pub const SIZE: usize = 128;
pub const ID_SEED: &[u8] = b"paranoid-identity-v1";
pub const NAME_SEED: &[u8] = b"paranoid-name-v1";

fn name(data: &[u8]) -> Result<&[u8], ProgramError> {
    if data.len() < 2 || data[0] != 1 {
        return Err(ProgramError::InvalidInstructionData);
    }
    let n = usize::from(data[1]);
    if !(3..=24).contains(&n) || data.len() != n + 2 {
        return Err(ProgramError::InvalidInstructionData);
    }
    let name = &data[2..];
    if !name[0].is_ascii_lowercase()
        || !name
            .iter()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || *c == b'_')
    {
        return Err(ProgramError::InvalidInstructionData);
    }
    Ok(name)
}

fn record(magic: &[u8; 8], bump: u8, owner: &Pubkey, other: &Pubkey, name: &[u8]) -> [u8; SIZE] {
    let mut bytes = [0u8; SIZE];
    bytes[..8].copy_from_slice(magic);
    bytes[8] = 1;
    bytes[9] = bump;
    bytes[10..42].copy_from_slice(owner.as_ref());
    bytes[42..74].copy_from_slice(other.as_ref());
    bytes[74] = name.len() as u8;
    bytes[75..75 + name.len()].copy_from_slice(name);
    bytes
}

fn vacant(account: &AccountInfo) -> bool {
    *account.owner == Pubkey::default() && account.data_is_empty() && !account.executable
}

fn initialize<'a>(
    payer: &AccountInfo<'a>,
    target: &AccountInfo<'a>,
    system: &AccountInfo<'a>,
    program: &Pubkey,
    seeds: &[&[u8]],
    bytes: &[u8; SIZE],
    rent: &Rent,
) -> ProgramResult {
    let shortfall = rent.minimum_balance(SIZE).saturating_sub(target.lamports());
    if shortfall != 0 {
        invoke(
            &system_instruction::transfer(payer.key, target.key, shortfall),
            &[payer.clone(), target.clone(), system.clone()],
        )?;
    }
    invoke_signed(
        &system_instruction::allocate(target.key, SIZE as u64),
        &[target.clone(), system.clone()],
        &[seeds],
    )?;
    invoke_signed(
        &system_instruction::assign(target.key, program),
        &[target.clone(), system.clone()],
        &[seeds],
    )?;
    target.try_borrow_mut_data()?.copy_from_slice(bytes);
    Ok(())
}

pub fn process_instruction(
    program: &Pubkey,
    accounts: &[AccountInfo],
    data: &[u8],
) -> ProgramResult {
    let name = name(data)?;
    if accounts.len() != 5 {
        return Err(ProgramError::NotEnoughAccountKeys);
    }
    let (payer, owner, identity, nickname, system) = (
        &accounts[0],
        &accounts[1],
        &accounts[2],
        &accounts[3],
        &accounts[4],
    );
    if !payer.is_signer || !owner.is_signer {
        return Err(ProgramError::MissingRequiredSignature);
    }
    if !payer.is_writable || !identity.is_writable || !nickname.is_writable {
        return Err(ProgramError::InvalidAccountData);
    }
    if *system.key != Pubkey::default() || !system.executable {
        return Err(ProgramError::IncorrectProgramId);
    }
    let (id_key, id_bump) = Pubkey::find_program_address(&[ID_SEED, owner.key.as_ref()], program);
    let (nick_key, nick_bump) = Pubkey::find_program_address(&[NAME_SEED, name], program);
    if *identity.key != id_key || *nickname.key != nick_key || identity.key == nickname.key {
        return Err(ProgramError::InvalidSeeds);
    }
    let id_bytes = record(b"PNDID001", id_bump, owner.key, nickname.key, name);
    let nick_bytes = record(b"PNDNAME1", nick_bump, owner.key, identity.key, name);
    let rent = Rent::get()?;
    if identity.owner == program && nickname.owner == program {
        if !identity.executable
            && !nickname.executable
            && *identity.try_borrow_data()? == id_bytes
            && *nickname.try_borrow_data()? == nick_bytes
            && rent.is_exempt(identity.lamports(), SIZE)
            && rent.is_exempt(nickname.lamports(), SIZE)
        {
            return Ok(());
        }
        return Err(ProgramError::AccountAlreadyInitialized);
    }
    if !vacant(identity) || !vacant(nickname) {
        return Err(ProgramError::AccountAlreadyInitialized);
    }
    initialize(
        payer,
        identity,
        system,
        program,
        &[ID_SEED, owner.key.as_ref(), &[id_bump]],
        &id_bytes,
        &rent,
    )?;
    initialize(
        payer,
        nickname,
        system,
        program,
        &[NAME_SEED, name, &[nick_bump]],
        &nick_bytes,
        &rent,
    )?;
    Ok(())
}
