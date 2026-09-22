//! Execute the compiled SBF under LiteSVM. No RPC, faucet or real key material.
use litesvm::LiteSVM;
use solana_account::Account;
use solana_address::Address;
use solana_instruction::{AccountMeta, Instruction};
use solana_keypair::Keypair;
use solana_message::Message;
use solana_signer::Signer;
use solana_transaction::Transaction;

struct Fixture {
    vm: LiteSVM,
    program: Address,
    payer: Keypair,
    owner: Keypair,
}
impl Fixture {
    fn new() -> Self {
        let mut vm = LiteSVM::new();
        let program = Address::new_unique();
        let payer = Keypair::new();
        let owner = Keypair::new();
        let elf = std::fs::read(concat!(
            env!("CARGO_MANIFEST_DIR"),
            "/../registry/target/deploy/paranoid_devnet_registry.so"
        ))
        .unwrap();
        vm.add_program(program, &elf).unwrap();
        vm.airdrop(&payer.pubkey(), 100_000_000).unwrap();
        Self {
            vm,
            program,
            payer,
            owner,
        }
    }
    fn ix(&self, name: &[u8]) -> Instruction {
        let (identity, _) = Address::find_program_address(
            &[b"paranoid-identity-v1", self.owner.pubkey().as_ref()],
            &self.program,
        );
        let (nickname, _) =
            Address::find_program_address(&[b"paranoid-name-v1", name], &self.program);
        let mut data = vec![1, name.len() as u8];
        data.extend(name);
        Instruction {
            program_id: self.program,
            accounts: vec![
                AccountMeta::new(self.payer.pubkey(), true),
                AccountMeta::new_readonly(self.owner.pubkey(), true),
                AccountMeta::new(identity, false),
                AccountMeta::new(nickname, false),
                AccountMeta::new_readonly(Address::default(), false),
            ],
            data,
        }
    }
    fn send(&mut self, ix: Instruction, owner_signs: bool) -> Result<(), String> {
        self.vm.expire_blockhash();
        let msg = Message::new(&[ix], Some(&self.payer.pubkey()));
        let tx = if owner_signs {
            Transaction::new(&[&self.payer, &self.owner], msg, self.vm.latest_blockhash())
        } else {
            Transaction::new(&[&self.payer], msg, self.vm.latest_blockhash())
        };
        self.vm
            .send_transaction(tx)
            .map(|_| ())
            .map_err(|e| format!("{:?}", e.err))
    }
    fn assert_absent(&self, key: Address) {
        assert!(self
            .vm
            .get_account(&key)
            .is_none_or(|a| a.data.is_empty() && a.owner == Address::default()));
    }
    fn account(&mut self, key: Address, owner: Address, data: Vec<u8>, lamports: u64) {
        self.vm
            .set_account(
                key,
                Account {
                    lamports,
                    data,
                    owner,
                    executable: false,
                    rent_epoch: 0,
                },
            )
            .unwrap();
    }
}

#[test]
fn registration_and_exact_retry_are_atomic_and_idempotent() {
    let mut f = Fixture::new();
    let ix = f.ix(b"alice_test");
    let (id, nick) = (ix.accounts[2].pubkey, ix.accounts[3].pubkey);
    f.send(ix.clone(), true).unwrap();
    let before = f.vm.get_account(&id).unwrap();
    let n = f.vm.get_account(&nick).unwrap();
    assert_eq!(before.owner, f.program);
    assert_eq!(n.owner, f.program);
    assert_eq!(before.data.len(), 128);
    assert_eq!(&before.data[..8], b"PNDID001");
    assert_eq!(&n.data[..8], b"PNDNAME1");
    assert_eq!(before.data[8], 1);
    assert_eq!(&before.data[10..42], f.owner.pubkey().as_ref());
    assert_eq!(&before.data[42..74], nick.as_ref());
    assert_eq!(&n.data[42..74], id.as_ref());
    assert_eq!(&before.data[75..85], b"alice_test");
    assert!(before.data[85..].iter().all(|b| *b == 0));
    f.send(ix, true).unwrap();
    assert_eq!(f.vm.get_account(&id).unwrap(), before);
    assert_eq!(f.vm.get_account(&nick).unwrap(), n);
}

#[test]
fn rejects_bad_instruction_names_versions_and_lengths_without_creating_accounts() {
    let cases = vec![
        vec![],
        vec![1],
        vec![2, 3, b'a', b'b', b'c'],
        vec![1, 2, b'a', b'b'],
        vec![1, 3, b'A', b'b', b'c'],
        vec![1, 3, b'1', b'b', b'c'],
        vec![1, 3, b'a', b'-', b'c'],
        vec![1, 3, b'a', 0xff, b'c'],
        vec![1, 3, b'a', b'b', b'c', 0],
        vec![1, 25],
    ];
    for data in cases {
        let mut f = Fixture::new();
        let mut ix = f.ix(b"abc");
        let id = ix.accounts[2].pubkey;
        ix.data = data;
        assert!(f
            .send(ix, true)
            .unwrap_err()
            .contains("InvalidInstructionData"));
        f.assert_absent(id);
    }
}

#[test]
fn missing_owner_signature_is_rejected() {
    let mut f = Fixture::new();
    let mut ix = f.ix(b"abc");
    let id = ix.accounts[2].pubkey;
    ix.accounts[1].is_signer = false;
    assert!(f
        .send(ix, false)
        .unwrap_err()
        .contains("MissingRequiredSignature"));
    f.assert_absent(id);
}
#[test]
fn wrong_pda_or_system_program_is_rejected() {
    for position in [2, 3, 4] {
        let mut f = Fixture::new();
        let mut ix = f.ix(b"abc");
        let id = ix.accounts[2].pubkey;
        ix.accounts[position].pubkey = Address::new_unique();
        assert!(f.send(ix, true).is_err());
        f.assert_absent(id);
    }
}
#[test]
fn read_only_record_is_rejected() {
    for position in [2, 3] {
        let mut f = Fixture::new();
        let mut ix = f.ix(b"abc");
        let id = ix.accounts[2].pubkey;
        ix.accounts[position].is_writable = false;
        assert!(f.send(ix, true).is_err());
        f.assert_absent(id);
    }
}
#[test]
fn occupied_name_does_not_create_another_identity() {
    let mut f = Fixture::new();
    let ix = f.ix(b"abc");
    let nick = ix.accounts[3].pubkey;
    f.send(ix, true).unwrap();
    let before = f.vm.get_account(&nick).unwrap();
    f.owner = Keypair::new();
    let ix = f.ix(b"abc");
    let id = ix.accounts[2].pubkey;
    assert!(f.send(ix, true).is_err());
    f.assert_absent(id);
    assert_eq!(f.vm.get_account(&nick).unwrap(), before);
}
#[test]
fn one_identity_cannot_register_a_second_name() {
    let mut f = Fixture::new();
    let ix = f.ix(b"abc");
    f.send(ix, true).unwrap();
    let second = f.ix(b"other");
    let nick = second.accounts[3].pubkey;
    assert!(f.send(second, true).is_err());
    f.assert_absent(nick);
}
#[test]
fn prefunded_system_pdas_work_without_refunding_excess() {
    for prefund in [1, 5_000_000] {
        let mut f = Fixture::new();
        let ix = f.ix(b"abc");
        let (id, nick) = (ix.accounts[2].pubkey, ix.accounts[3].pubkey);
        f.account(id, Address::default(), vec![], prefund);
        f.account(nick, Address::default(), vec![], prefund);
        f.send(ix, true).unwrap();
        assert!(f.vm.get_account(&id).unwrap().lamports >= prefund);
        assert_eq!(f.vm.get_account(&nick).unwrap().data.len(), 128);
    }
}
#[test]
fn foreign_owner_partial_or_corrupt_state_is_rejected_without_repair() {
    for mode in 0..4 {
        let mut f = Fixture::new();
        let ix = f.ix(b"abc");
        let (id, nick) = (ix.accounts[2].pubkey, ix.accounts[3].pubkey);
        if mode == 0 {
            f.account(id, Address::new_unique(), vec![0; 128], 5_000_000);
        } else if mode == 1 {
            f.account(id, f.program, vec![0; 128], 5_000_000);
        } else {
            f.send(ix.clone(), true).unwrap();
            let mut a = f.vm.get_account(&id).unwrap();
            a.data[if mode == 2 { 9 } else { 127 }] ^= 1;
            f.vm.set_account(id, a).unwrap();
        }
        let before = f.vm.get_account(&id);
        let nb = f.vm.get_account(&nick);
        assert!(f.send(ix, true).is_err());
        assert_eq!(f.vm.get_account(&id), before);
        assert_eq!(f.vm.get_account(&nick), nb);
    }
}
#[test]
fn failure_of_second_allocation_rolls_back_first_record() {
    let mut f = Fixture::new();
    let ix = f.ix(b"abc");
    let (id, nick) = (ix.accounts[2].pubkey, ix.accounts[3].pubkey);
    let lamports = f.vm.minimum_balance_for_rent_exemption(128) + 20_000;
    f.account(f.payer.pubkey(), Address::default(), vec![], lamports);
    assert!(f.send(ix, true).is_err());
    f.assert_absent(id);
    f.assert_absent(nick);
}
