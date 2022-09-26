import { expect } from 'chai';
import { network, ethers } from 'hardhat';
import { SignerWithAddress } from '@nomiclabs/hardhat-ethers/signers';
import { Address } from 'hardhat-deploy/dist/types';
import { BigNumber, BigNumberish, ContractTransaction } from 'ethers';

import {
  SlashIndicator,
  SlashIndicator__factory,
  Staking,
  Staking__factory,
  MockRoninValidatorSetExtends__factory,
  MockRoninValidatorSetExtends,
} from '../../src/types';

import { expects as RoninValidatorSetExpects } from '../helpers/ronin-validator-set';
import { mineBatchTxs } from '../helpers/utils';
import { SlashType } from '../../src/script/slash-indicator';
import { GovernanceAdminInterface, initTest } from '../helpers/fixture';

let slashContract: SlashIndicator;
let stakingContract: Staking;
let validatorContract: MockRoninValidatorSetExtends;
let governanceAdmin: GovernanceAdminInterface;

let coinbase: SignerWithAddress;
let deployer: SignerWithAddress;
let governor: SignerWithAddress;
let validatorCandidates: SignerWithAddress[];

const felonyJailBlocks = 28800 * 2;
const misdemeanorThreshold = 10;
const felonyThreshold = 20;
const slashFelonyAmount = BigNumber.from(1);
const slashDoubleSignAmount = 1000;
const minValidatorBalance = BigNumber.from(100);
const numberOfBlocksInEpoch = 600;
const numberOfEpochsInPeriod = 48;

describe('[Integration] Slash validators', () => {
  before(async () => {
    [deployer, coinbase, governor, ...validatorCandidates] = await ethers.getSigners();
    await network.provider.send('hardhat_setCoinbase', [coinbase.address]);
    governanceAdmin = new GovernanceAdminInterface(governor);

    const { slashContractAddress, stakingContractAddress, validatorContractAddress } = await initTest(
      'ActionSlashValidators'
    )({
      felonyJailBlocks,
      misdemeanorThreshold,
      felonyThreshold,
      slashFelonyAmount,
      slashDoubleSignAmount,
      minValidatorBalance,
      governanceAdmin: governanceAdmin.address,
    });

    slashContract = SlashIndicator__factory.connect(slashContractAddress, deployer);
    stakingContract = Staking__factory.connect(stakingContractAddress, deployer);
    validatorContract = MockRoninValidatorSetExtends__factory.connect(validatorContractAddress, deployer);

    const mockValidatorLogic = await new MockRoninValidatorSetExtends__factory(deployer).deploy();
    await mockValidatorLogic.deployed();
    governanceAdmin.upgrade(validatorContract.address, mockValidatorLogic.address);
    await network.provider.send('hardhat_mine', [
      ethers.utils.hexStripZeros(BigNumber.from(numberOfBlocksInEpoch * numberOfEpochsInPeriod).toHexString()),
    ]);
  });

  describe('Slash one validator', async () => {
    let expectingValidatorSet: Address[] = [];
    let period: BigNumberish;

    before(async () => {
      const currentBlock = await ethers.provider.getBlockNumber();
      period = await validatorContract.periodOf(currentBlock);
      await network.provider.send('hardhat_setCoinbase', [coinbase.address]);
    });

    describe('Slash misdemeanor validator', async () => {
      it('Should the ValidatorSet contract emit event', async () => {
        let slasheeIdx = 1;
        let slashee = validatorCandidates[slasheeIdx];

        for (let i = 0; i < misdemeanorThreshold - 1; i++) {
          await slashContract.connect(coinbase).slash(slashee.address);
        }
        let tx = slashContract.connect(coinbase).slash(slashee.address);

        await expect(tx)
          .to.emit(slashContract, 'UnavailabilitySlashed')
          .withArgs(slashee.address, SlashType.MISDEMEANOR, period);
        await expect(tx).to.emit(validatorContract, 'ValidatorPunished').withArgs(slashee.address, 0, 0);
      });
    });

    describe('Slash felony validator -- when the validators balance is sufficient after being slashed', async () => {
      let updateValidatorTx: ContractTransaction;
      let slashValidatorTx: ContractTransaction;
      let slasheeIdx: number;
      let slashee: SignerWithAddress;
      let slasheeInitStakingAmount: BigNumber;

      before(async () => {
        slasheeIdx = 2;
        slashee = validatorCandidates[slasheeIdx];
        slasheeInitStakingAmount = minValidatorBalance.add(slashFelonyAmount.mul(10));
        await stakingContract
          .connect(slashee)
          .proposeValidator(slashee.address, slashee.address, slashee.address, 2_00, {
            value: slasheeInitStakingAmount,
          });

        expect(await stakingContract.balanceOf(slashee.address, slashee.address)).eq(slasheeInitStakingAmount);

        await mineBatchTxs(async () => {
          await validatorContract.connect(coinbase).endEpoch();
          updateValidatorTx = await validatorContract.connect(coinbase).wrapUpEpoch();
        });

        expectingValidatorSet.push(slashee.address);
        await RoninValidatorSetExpects.emitValidatorSetUpdatedEvent(updateValidatorTx!, expectingValidatorSet);

        expect(await validatorContract.getValidators()).eql(expectingValidatorSet);
      });

      it('Should the ValidatorSet contract emit event', async () => {
        for (let i = 0; i < felonyThreshold - 1; i++) {
          await slashContract.connect(coinbase).slash(slashee.address);
        }
        slashValidatorTx = await slashContract.connect(coinbase).slash(slashee.address);

        await expect(slashValidatorTx)
          .to.emit(slashContract, 'UnavailabilitySlashed')
          .withArgs(slashee.address, SlashType.FELONY, period);

        let blockNumber = await network.provider.send('eth_blockNumber');

        await expect(slashValidatorTx)
          .to.emit(validatorContract, 'ValidatorPunished')
          .withArgs(slashee.address, BigNumber.from(blockNumber).add(felonyJailBlocks), slashFelonyAmount);
      });

      it('Should the validator is put in jail', async () => {
        let blockNumber = await network.provider.send('eth_blockNumber');
        expect(await validatorContract.getJailUntils(expectingValidatorSet)).eql([
          BigNumber.from(blockNumber).add(felonyJailBlocks),
        ]);
      });

      it('Should the Staking contract emit Unstaked event', async () => {
        await expect(slashValidatorTx)
          .to.emit(stakingContract, 'Unstaked')
          .withArgs(slashee.address, slashFelonyAmount);
      });

      it('Should the Staking contract emit Undelegated event', async () => {
        await expect(slashValidatorTx)
          .to.emit(stakingContract, 'Undelegated')
          .withArgs(slashee.address, slashee.address, slashFelonyAmount);
      });

      it('Should the Staking contract subtract staked amount from validator', async () => {
        let _expectingSlasheeStakingAmount = slasheeInitStakingAmount.sub(slashFelonyAmount);
        expect(await stakingContract.balanceOf(slashee.address, slashee.address)).eq(_expectingSlasheeStakingAmount);
      });

      it('Should the validator set exclude the jailed validator in the next epoch', async () => {
        await mineBatchTxs(async () => {
          await validatorContract.connect(coinbase).endEpoch();
          updateValidatorTx = await validatorContract.connect(coinbase).wrapUpEpoch();
        });
        expectingValidatorSet.pop();
        await RoninValidatorSetExpects.emitValidatorSetUpdatedEvent(updateValidatorTx!, expectingValidatorSet);
      });

      it('Should the validator candidate cannot re-join as a validator when jail time is not over', async () => {
        let _blockNumber = await network.provider.send('eth_blockNumber');
        let _jailUntil = await validatorContract.getJailUntils([slashee.address]);
        let _numOfBlockToEndJailTime = _jailUntil[0].sub(_blockNumber).sub(100);

        await network.provider.send('hardhat_mine', [_numOfBlockToEndJailTime.toHexString()]);
        await mineBatchTxs(async () => {
          await validatorContract.connect(coinbase).endEpoch();
          updateValidatorTx = await validatorContract.connect(coinbase).wrapUpEpoch();
        });

        await RoninValidatorSetExpects.emitValidatorSetUpdatedEvent(updateValidatorTx!, []);
      });

      it('Should the validator candidate re-join as a validator when jail time is over', async () => {
        let _blockNumber = await network.provider.send('eth_blockNumber');
        let _jailUntil = await validatorContract.getJailUntils([slashee.address]);
        let _numOfBlockToEndJailTime = _jailUntil[0].sub(_blockNumber);

        await network.provider.send('hardhat_mine', [_numOfBlockToEndJailTime.toHexString()]);
        await mineBatchTxs(async () => {
          await validatorContract.connect(coinbase).endEpoch();
          updateValidatorTx = await validatorContract.connect(coinbase).wrapUpEpoch();
        });
        expectingValidatorSet.push(slashee.address);
        await RoninValidatorSetExpects.emitValidatorSetUpdatedEvent(updateValidatorTx!, expectingValidatorSet);
      });
    });

    describe('Slash felony validator -- when the validators balance is equal to minimum balance', async () => {
      let updateValidatorTx: ContractTransaction;
      let slashValidatorTx: ContractTransaction;
      let slasheeIdx: number;
      let slashee: SignerWithAddress;
      let slasheeInitStakingAmount: BigNumber;

      before(async () => {
        slasheeIdx = 3;
        slashee = validatorCandidates[slasheeIdx];
        slasheeInitStakingAmount = minValidatorBalance;

        await stakingContract
          .connect(slashee)
          .proposeValidator(slashee.address, slashee.address, slashee.address, 2_00, {
            value: slasheeInitStakingAmount,
          });

        expect(await stakingContract.balanceOf(slashee.address, slashee.address)).eq(slasheeInitStakingAmount);

        await mineBatchTxs(async () => {
          await validatorContract.connect(coinbase).endEpoch();
          updateValidatorTx = await validatorContract.connect(coinbase).wrapUpEpoch();
        });
        expectingValidatorSet.push(slashee.address);
        await RoninValidatorSetExpects.emitValidatorSetUpdatedEvent(updateValidatorTx!, expectingValidatorSet);

        expect(await validatorContract.getValidators()).eql(expectingValidatorSet);
      });

      it('Should the ValidatorSet contract emit event', async () => {
        for (let i = 0; i < felonyThreshold - 1; i++) {
          await slashContract.connect(coinbase).slash(slashee.address);
        }
        slashValidatorTx = await slashContract.connect(coinbase).slash(slashee.address);

        await expect(slashValidatorTx)
          .to.emit(slashContract, 'UnavailabilitySlashed')
          .withArgs(slashee.address, SlashType.FELONY, period);

        let blockNumber = await network.provider.send('eth_blockNumber');

        await expect(slashValidatorTx)
          .to.emit(validatorContract, 'ValidatorPunished')
          .withArgs(slashee.address, BigNumber.from(blockNumber).add(felonyJailBlocks), slashFelonyAmount);
      });

      it('Should the validator is put in jail', async () => {
        let blockNumber = await network.provider.send('eth_blockNumber');
        expect(await validatorContract.getJailUntils([slashee.address])).eql([
          BigNumber.from(blockNumber).add(felonyJailBlocks),
        ]);
      });

      it('Should the Staking contract emit Unstaked event', async () => {
        await expect(slashValidatorTx)
          .to.emit(stakingContract, 'Unstaked')
          .withArgs(slashee.address, slashFelonyAmount);
      });

      it('Should the Staking contract emit Undelegated event', async () => {
        await expect(slashValidatorTx)
          .to.emit(stakingContract, 'Undelegated')
          .withArgs(slashee.address, slashee.address, slashFelonyAmount);
      });

      it('Should the Staking contract subtract staked amount from validator', async () => {
        let _expectingSlasheeStakingAmount = slasheeInitStakingAmount.sub(slashFelonyAmount);
        expect(await stakingContract.balanceOf(slashee.address, slashee.address)).eq(_expectingSlasheeStakingAmount);
      });

      it('Should the validator set exclude the jailed validator in the next epoch', async () => {
        await mineBatchTxs(async () => {
          await validatorContract.connect(coinbase).endEpoch();
          updateValidatorTx = await validatorContract.connect(coinbase).wrapUpEpoch();
        });
        expectingValidatorSet.pop();
        await RoninValidatorSetExpects.emitValidatorSetUpdatedEvent(updateValidatorTx!, expectingValidatorSet);
      });

      it('Should the validator candidate cannot re-join as a validator when jail time is not over', async () => {
        let _blockNumber = await network.provider.send('eth_blockNumber');
        let _jailUntil = await validatorContract.getJailUntils([slashee.address]);
        let _numOfBlockToEndJailTime = _jailUntil[0].sub(_blockNumber).sub(100);

        await network.provider.send('hardhat_mine', [_numOfBlockToEndJailTime.toHexString()]);
        await mineBatchTxs(async () => {
          await validatorContract.connect(coinbase).endEpoch();
          updateValidatorTx = await validatorContract.connect(coinbase).wrapUpEpoch();
        });

        await RoninValidatorSetExpects.emitValidatorSetUpdatedEvent(updateValidatorTx!, expectingValidatorSet);
      });

      it('Should the validator candidate cannot join as a validator when jail time is over, due to insufficient fund', async () => {
        let _blockNumber = await network.provider.send('eth_blockNumber');
        let _jailUntil = await validatorContract.getJailUntils([slashee.address]);
        let _numOfBlockToEndJailTime = _jailUntil[0].sub(_blockNumber);

        await network.provider.send('hardhat_mine', [_numOfBlockToEndJailTime.toHexString()]);
        await mineBatchTxs(async () => {
          await validatorContract.connect(coinbase).endEpoch();
          updateValidatorTx = await validatorContract.connect(coinbase).wrapUpEpoch();
        });
        await RoninValidatorSetExpects.emitValidatorSetUpdatedEvent(updateValidatorTx!, expectingValidatorSet);
      });

      it('Should the validator top-up balance for being sufficient minimum balance of a validator', async () => {
        let topUpTx = await stakingContract.connect(slashee).stake(slashee.address, {
          value: slashFelonyAmount,
        });

        await expect(topUpTx).to.emit(stakingContract, 'Staked').withArgs(slashee.address, slashFelonyAmount);
        await expect(topUpTx)
          .to.emit(stakingContract, 'Delegated')
          .withArgs(slashee.address, slashee.address, slashFelonyAmount);
      });

      // NOTE: the candidate is kicked right after the epoch is ended.
      it.skip('Should the validator be able to re-join the validator set', async () => {
        await mineBatchTxs(async () => {
          await validatorContract.connect(coinbase).endEpoch();
          updateValidatorTx = await validatorContract.connect(coinbase).wrapUpEpoch();
        });
        expectingValidatorSet.push(slashee.address);
        await RoninValidatorSetExpects.emitValidatorSetUpdatedEvent(updateValidatorTx!, expectingValidatorSet);
      });
    });
  });

  // TODO(Bao): Test for reward amount of validators and delegators
});
