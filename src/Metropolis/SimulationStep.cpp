/**
 * Base class for an iteration of the simulation.
 */
#include <set>

#include "SimBox.h"
#include "GPUCopy.h"
#include "SimulationStep.h"

#define VERBOSE true
#define ENABLE_BOND 1
#define ENABLE_ANGLE 1
#define ENABLE_DIHEDRAL 0
#define ENABLE_TUNING true
#define RATIO_MARGIN 0.0001
#define TARGET_RATIO 0.4

/** Construct a new SimulationStep from a SimBox pointer */
SimulationStep::SimulationStep(SimBox *box) {
  SimCalcs::setSB(box);
}

Real SimulationStep::calcMoleculeEnergy(int currMol, int startMol, bool verbose) {
  return calcMolecularEnergyContribution(currMol, startMol) +
         calcIntraMolecularEnergy(currMol, verbose);
}

Real SimulationStep::calcIntraMolecularEnergy(int molIdx, bool verbose) {
  return SimCalcs::calcIntraMolecularEnergy(molIdx, verbose);
}

/** Returns the index of a random molecule within the simulation box */
int SimulationStep::chooseMolecule(SimBox *box) {
  return (int) randomReal(0, box->numMolecules);
}

/** Perturb a given molecule */
void SimulationStep::changeMolecule(int molIdx, SimBox *box, bool verbose) {
  SimCalcs::changeMolecule(molIdx, verbose);
}

/** Move a molecule back to its original position */
void SimulationStep::rollback(int molIdx, SimBox *box) {
  SimCalcs::rollback(molIdx);
}

/** Determines the total energy of the box */
Real SimulationStep::calcSystemEnergy(Real &subLJ, Real &subCharge,
                                      int numMolecules) {
  Real intra = 0, inter = 0;
  Real bondE = 0, angleE = 0, nonBondE = 0;
  Real totalBondE = 0, totalAngleE = 0, totalNonBondE = 0;

  Real total = subLJ + subCharge;
  for (int mol = 0; mol < numMolecules; mol++) {
    total += calcMoleculeEnergy(mol, mol, false);

    if (VERBOSE) {
      inter += calcMolecularEnergyContribution(mol, mol);
      intra += SimCalcs::calcIntraMolecularEnergy(mol, false);
      bondE = SimCalcs::bondEnergy(mol, false);
      angleE = SimCalcs::angleEnergy(mol, false);
      nonBondE = SimCalcs::calcIntraMolecularEnergy(mol, false) - bondE - angleE;
      totalBondE += bondE;
      totalAngleE += angleE;
      totalNonBondE += nonBondE;
    }

  }

  if (VERBOSE) {
    std::cout << "Inter: " << inter << " Intra: " << intra << std::endl;
    std::cout << "Bond: " << totalBondE << std::endl
              << "Angle: " << totalAngleE << std::endl
              << "Non-Bond: " << totalNonBondE << std::endl << std::endl;
  }

  return total;
}


// ----- SimCalcs Definitions -----


SimBox* SimCalcs::sb;
int SimCalcs::on_gpu;

Real SimCalcs::calcIntraMolecularEnergy(int molIdx, bool verbose) {
  int** moleculeData = GPUCopy::moleculeDataPtr();
  int molStart = moleculeData[MOL_START][molIdx];
  int molEnd = molStart + moleculeData[MOL_LEN][molIdx];
  int molType = moleculeData[MOL_TYPE][molIdx];
  Real** aCoords = GPUCopy::atomCoordinatesPtr();
  Real** atomData = GPUCopy::atomDataPtr();

  Real out = 0.0;
  out += angleEnergy(molIdx, verbose);
  out += bondEnergy(molIdx, verbose);

  // DEBUG
  if (verbose && VERBOSE) {
    std::cout << "Calculating LJ and Charge Energy for molecule " << molIdx << std::endl;
  }

  // Calculate intramolecular LJ and Coulomb energy if necessary
  for (int i = molStart; i < molEnd; i++) {
    for (int j = i + 1; j < molEnd; j++) {
      Real fudgeFactor = 1.0;
      for (int k = 0; ; k++) {
        int val = sb->excludeAtoms[molType][i - molStart][k];
        if (val == -1) {
          break;
        } else if (val == j - molStart) {
          fudgeFactor = 0.0;
          break;
        }
      }
      if (fudgeFactor > 0.0) {
        for (int k = 0; ; k++) {
          int val = sb->fudgeAtoms[molType][i - molStart][k];
          if (val == -1) {
            break;
          } else if (val == j - molStart) {
            fudgeFactor = 0.5;
            break;
          }
        }
      }
      if (fudgeFactor > 0.0) {
        Real r2 = calcAtomDistSquared(i, j, aCoords, sb->size);
        Real r = sqrt(r2);
        Real energy = calcLJEnergy(i, j, r2, atomData);
        energy += calcChargeEnergy(i, j, r, atomData);
        out += fudgeFactor * energy;

        // DEBUG
        if (verbose && VERBOSE) {
          std::cout << "Atoms " << i << " " << j << ": " << " LJ: " << calcLJEnergy(i, j, r, atomData)
                    << "Charge: " << calcChargeEnergy(i, j, r, atomData) << std::endl;
        }
      } else { // DEBUG
        if (verbose && VERBOSE) {
          std::cout << "Atoms " << i << " " << j << ": Skipped" << std::endl;
        }
      }
    }
  }
  // DEBUG
  if (verbose && VERBOSE) std::cout << std::endl;

  return out;
}

Real SimCalcs::angleEnergy(int molIdx, bool verbose) {
  // DEBUG
  if (verbose && VERBOSE) {
    std::cout << "Angle Energy for molecule " << molIdx << std::endl;
  }

  int** moleculeData = GPUCopy::moleculeDataPtr();
  Real out = 0;
  int angleStart = moleculeData[MOL_ANGLE_START][molIdx];
  int angleEnd = angleStart + moleculeData[MOL_ANGLE_COUNT][molIdx];
  for (int i = angleStart; i < angleEnd; i++) {
    if ((bool) sb->angleData[ANGLE_VARIABLE][i]) {
      Real diff = sb->angleData[ANGLE_EQANGLE][i] - sb->angleSizes[i];
      out += sb->angleData[ANGLE_KANGLE][i] * diff * diff;

      // DEBUG
      if (verbose && VERBOSE) {
        std::cout << "Angle: " << i << " EQ: " << sb->angleData[ANGLE_EQANGLE][i]
                  << " Val: " << sb->angleSizes[i] << " Diff: " << diff
                  << " Force K: " << sb->angleData[ANGLE_KANGLE][i]
                  << " Total E: " << sb->angleData[ANGLE_KANGLE][i] * diff * diff
                  << std::endl;
      }
    }
  }

  // DEBUG
  if (verbose && VERBOSE) {
    std::cout << "Total angle energy: " << out << std::endl;
    std::cout << std::endl;
  }

  return out;
}

void SimCalcs::expandAngle(int molIdx, int angleIdx, Real expandDeg) {
  int** moleculeData = GPUCopy::moleculeDataPtr();
  Real* angleSizes = GPUCopy::anglesPtr();
  int bondStart = moleculeData[MOL_BOND_START][molIdx];
  int bondEnd = bondStart + moleculeData[MOL_BOND_COUNT][molIdx];
  int angleStart = moleculeData[MOL_ANGLE_START][molIdx];
  int startIdx = moleculeData[MOL_START][molIdx];
  int molSize = moleculeData[MOL_LEN][molIdx];
  int end1 = (int)sb->angleData[ANGLE_A1_IDX][angleStart + angleIdx];
  int end2 = (int)sb->angleData[ANGLE_A2_IDX][angleStart + angleIdx];
  int mid = (int)sb->angleData[ANGLE_MID_IDX][angleStart + angleIdx];
  Real** aCoords = GPUCopy::atomCoordinatesPtr();


  // Create a disjoint set of the atoms in the molecule
  for (int i = 0; i < molSize; i++) {
    sb->unionFindParent[i] = i;
  }

  // Union atoms connected by a bond
  for (int i = bondStart; i < bondEnd; i++) {
    int a1 = (int)sb->bondData[BOND_A1_IDX][i];
    int a2 = (int)sb->bondData[BOND_A2_IDX][i];
    if (a1 == mid || a2 == mid)
      continue;
    unionAtoms(a1 - startIdx, a2 - startIdx);
  }

  int group1 = find(end1 - startIdx);
  int group2 = find(end2 - startIdx);
  if (group1 == group2) {
    // std::cout << "ERROR: EXPANDING ANGLE IN A RING!" << std::endl;
    return;
  }
  Real DEG2RAD = 3.14159256358979323846264 / 180.0;
  Real end1Mid[NUM_DIMENSIONS];
  Real end2Mid[NUM_DIMENSIONS];
  Real normal[NUM_DIMENSIONS];
  Real mvector[NUM_DIMENSIONS];
  for (int i = 0; i < NUM_DIMENSIONS; i++) {
    end1Mid[i] = aCoords[i][mid] - aCoords[i][end1];
    end2Mid[i] = aCoords[i][mid] - aCoords[i][end2];
    mvector[i] = aCoords[i][mid];
  }
  normal[0] = end1Mid[1] * end2Mid[2] - end2Mid[1] * end1Mid[2];
  normal[1] = end2Mid[0] * end1Mid[2] - end1Mid[0] * end2Mid[2];
  normal[2] = end1Mid[0] * end2Mid[1] - end2Mid[0] * end1Mid[1];
  Real normLen = 0.0;
  for (int i = 0; i < NUM_DIMENSIONS; i++) {
    normLen += normal[i] * normal[i];
  }
  normLen = sqrt(normLen);
  for (int i = 0; i < NUM_DIMENSIONS; i++) {
    normal[i] = normal[i] / normLen;
  }


  for (int i = startIdx; i < startIdx + molSize; i++) {
    Real theta;
    Real point[NUM_DIMENSIONS];
    Real dot = 0.0;
    Real cross[NUM_DIMENSIONS];
    if (find(i - startIdx) == group1) {
      theta = expandDeg * -DEG2RAD;
    } else if (find(i - startIdx) == group2) {
      theta = expandDeg * DEG2RAD;
    } else {
      continue;
    }

    for (int j = 0; j < NUM_DIMENSIONS; j++) {
      point[j] = aCoords[j][i] - mvector[j];
      dot += point[j] * normal[j];
    }

    cross[0] = normal[1] * point[2] - point[1] * normal[2];
    cross[1] = point[0] * normal[2] - normal[0] * point[2];
    cross[2] = normal[0] * point[1] - point[0] * normal[1];

    for (int j = 0; j < NUM_DIMENSIONS; j++) {
      point[j] = (normal[j] * dot * (1 - cos(theta)) + point[j] * cos(theta) +
                  cross[j] * sin(theta));
      aCoords[j][i] = point[j] + mvector[j];
    }
  }

  angleSizes[angleStart + angleIdx] += expandDeg;
}

Real SimCalcs::bondEnergy(int molIdx, bool verbose) {
  // DEBUG
  if (verbose && VERBOSE) {
    std::cout << "Bond Energy for molecule " << molIdx << std::endl;
  }

  Real out = 0;
  int bondStart = sb->moleculeData[MOL_BOND_START][molIdx];
  int bondEnd = bondStart + sb->moleculeData[MOL_BOND_COUNT][molIdx];
  for (int i = bondStart; i < bondEnd; i++) {
    if ((bool) sb->bondData[BOND_VARIABLE][i]) {
      Real diff = sb->bondData[BOND_EQDIST][i] - sb->bondLengths[i];
      out += sb->bondData[BOND_KBOND][i] * diff * diff;

      // DEBUG
      if (verbose && VERBOSE) {
        std::cout << "Bond: " << i << " EQ: " << sb->bondData[BOND_EQDIST][i]
                  << " Val: " << sb->bondLengths[i] << " Diff: " << diff
                  << " Force K: " << sb->bondData[BOND_KBOND][i]
                  << " Total E: " << sb->bondData[BOND_KBOND][i] * diff * diff
                  << std::endl;
      }
    }
  }

  // DEBUG
  if (verbose && VERBOSE) {
    std::cout << "Total bond energy: " << out << std::endl;
    std::cout << std::endl;
  }

  return out;
}

void SimCalcs::stretchBond(int molIdx, int bondIdx, Real stretchDist) {
  Real* bondLengths = GPUCopy::bondsPtr();
  int bondStart = sb->moleculeData[MOL_BOND_START][molIdx];
  int bondEnd = bondStart + sb->moleculeData[MOL_BOND_COUNT][molIdx];
  int startIdx = sb->moleculeData[MOL_START][molIdx];
  int molSize = sb->moleculeData[MOL_LEN][molIdx];
  int end1 = (int)sb->bondData[BOND_A1_IDX][bondStart + bondIdx];
  int end2 = (int)sb->bondData[BOND_A2_IDX][bondStart + bondIdx];
  Real** aCoords = GPUCopy::atomCoordinatesPtr();

  for (int i = 0; i < molSize; i++) {
    sb->unionFindParent[i] = i;
  }

  // Split the molecule atoms into two disjoint sets around the bond
  for (int i = bondStart; i < bondEnd; i++) {
    if (i == bondIdx + bondStart)
      continue;
    int a1 = (int)sb->bondData[BOND_A1_IDX][i] - startIdx;
    int a2 = (int)sb->bondData[BOND_A2_IDX][i] - startIdx;
    unionAtoms(a1, a2);
  }
  int side1 = find(end1 - startIdx);
  int side2 = find(end2 - startIdx);
  if (side1 == side2) {
    // std::cerr << "ERROR: EXPANDING BOND IN A RING!" << std::endl;
    return;
  }

  // Move each atom the appropriate distance for the bond stretch
  Real v[NUM_DIMENSIONS];
  Real denon = 0.0;
  for (int i = 0; i < NUM_DIMENSIONS; i++) {
    v[i] = aCoords[i][end2] - aCoords[i][end1];
    denon += v[i] * v[i];
  }
  denon = sqrt(denon);
  for (int i = 0; i < NUM_DIMENSIONS; i++) {
    v[i] = v[i] / denon / 2.0;
  }
  for (int i = 0; i < molSize; i++) {
    if (find(i) == side2) {
      for (int j = 0; j < NUM_DIMENSIONS; j++) {
        aCoords[j][i + startIdx] += v[j] * stretchDist;
      }
    } else {
      for (int j = 0; j < NUM_DIMENSIONS; j++) {
        aCoords[j][i + startIdx] -= v[j] * stretchDist;
      }
    }
  }

  // Record the actual bond stretch
  bondLengths[bondStart + bondIdx] += stretchDist;
}

bool SimCalcs::moleculesInRange(int p1Start, int p1End, int p2Start, int p2End,
                                Real** atomCoords, Real* bSize,
                                int* primaryIndexes, Real cutoff) {
  bool out = false;
  for (int p1Idx = p1Start; p1Idx < p1End; p1Idx++) {
    int p1 = primaryIndexes[p1Idx];
    for (int p2Idx = p2Start; p2Idx < p2End; p2Idx++) {
      int p2 = primaryIndexes[p2Idx];
      out |= (calcAtomDistSquared(p1, p2, atomCoords, bSize) <=
              cutoff * cutoff);
    }
  }
  return out;
}

Real SimCalcs::calcAtomDistSquared(int a1, int a2, Real** aCoords,
                                   Real* bSize) {
  Real dx = makePeriodic(aCoords[X_COORD][a2] - aCoords[X_COORD][a1],
                         X_COORD, bSize);
  Real dy = makePeriodic(aCoords[Y_COORD][a2] - aCoords[Y_COORD][a1],
                         Y_COORD, bSize);
  Real dz = makePeriodic(aCoords[Z_COORD][a2] - aCoords[Z_COORD][a1],
                         Z_COORD, bSize);

  return dx * dx + dy * dy + dz * dz;
}

Real SimCalcs::calcLJEnergy(int a1, int a2, Real r2, Real** aData) {
  if (r2 == 0.0) {
    return 0.0;
  } else {
    const Real sigma = SimCalcs::calcBlending(aData[ATOM_SIGMA][a1],
        aData[ATOM_SIGMA][a2]);
    const Real epsilon = SimCalcs::calcBlending(aData[ATOM_EPSILON][a1],
        aData[ATOM_EPSILON][a2]);

    const Real s2r2 = pow(sigma, 2) / r2;
    const Real s6r6 = pow(s2r2, 3);
    const Real s12r12 = pow(s6r6, 2);
    return 4.0 * epsilon * (s12r12 - s6r6);
  }
}

Real SimCalcs::calcChargeEnergy(int a1, int a2, Real r, Real** aData) {
  if (r == 0.0) {
    return 0.0;
  } else {
    const Real e = 332.06;
    return (aData[ATOM_CHARGE][a1] * aData[ATOM_CHARGE][a2] * e) / r;
  }
}

Real SimCalcs::calcBlending (Real a, Real b) {
  if (a * b >= 0) {
    return sqrt(a*b);
  } else {
    return sqrt(-1*a*b);
  }
}

Real SimCalcs::makePeriodic(Real x, int dimension, Real* bSize) {
  Real dimLength = bSize[dimension];

  int lt = (x < -0.5 * dimLength); // 1 or 0
  x += lt * dimLength;
  int gt = (x > 0.5 * dimLength);  // 1 or 0
  x -= gt * dimLength;
  return x;
}

void SimCalcs::rotateAtom(int aIdx, int pivotIdx, Real rotX, Real rotY,
                          Real rotZ, Real** aCoords) {
  Real pX = aCoords[X_COORD][pivotIdx];
  Real pY = aCoords[Y_COORD][pivotIdx];
  Real pZ = aCoords[Z_COORD][pivotIdx];

  translateAtom(aIdx, -pX, -pY, -pZ, aCoords);
  rotateX(aIdx, rotX, aCoords);
  rotateY(aIdx, rotY, aCoords);
  rotateZ(aIdx, rotZ, aCoords);
  translateAtom(aIdx, pX, pY, pZ, aCoords);
}

void SimCalcs::rotateX(int aIdx, Real angleDeg, Real** aCoords) {
  Real angleRad = angleDeg * 3.14159265358979 / 180.0;
  Real oldY = aCoords[Y_COORD][aIdx];
  Real oldZ = aCoords[Z_COORD][aIdx];
  aCoords[Y_COORD][aIdx] = oldY * cos(angleRad) + oldZ * sin(angleRad);
  aCoords[Z_COORD][aIdx] = oldZ * cos(angleRad) - oldY * sin(angleRad);
}

void SimCalcs::rotateY(int aIdx, Real angleDeg, Real** aCoords) {
  Real angleRad = angleDeg * 3.14159265358979 / 180.0;
  Real oldZ = aCoords[Z_COORD][aIdx];
  Real oldX = aCoords[X_COORD][aIdx];
  aCoords[Z_COORD][aIdx] = oldZ * cos(angleRad) + oldX * sin(angleRad);
  aCoords[X_COORD][aIdx] = oldX * cos(angleRad) - oldZ * sin(angleRad);
}

void SimCalcs::rotateZ(int aIdx, Real angleDeg, Real** aCoords) {
  Real angleRad = angleDeg * 3.14159265358979 / 180.0;
  Real oldX = aCoords[X_COORD][aIdx];
  Real oldY = aCoords[Y_COORD][aIdx];
  aCoords[X_COORD][aIdx] = oldX * cos(angleRad) + oldY * sin(angleRad);
  aCoords[Y_COORD][aIdx] = oldY * cos(angleRad) - oldX * sin(angleRad);
}

void SimCalcs::changeMolecule(int molIdx, bool verbose) {
  // Intermolecular moves first, to save proper rollback positions
  intermolecularMove(molIdx);
  intramolecularMove(molIdx, verbose);
}

void SimCalcs::intermolecularMove(int molIdx) {
  Real maxT = sb->maxTranslate;
  Real maxR = sb->maxRotate;

  int molStart = sb->moleculeData[MOL_START][molIdx];
  int molLen = sb->moleculeData[MOL_LEN][molIdx];

  int vertexIdx = (int)randomReal(0, molLen);

  const Real deltaX = randomReal(-maxT, maxT);
  const Real deltaY = randomReal(-maxT, maxT);
  const Real deltaZ = randomReal(-maxT, maxT);

  const Real rotX = randomReal(-maxR, maxR);
  const Real rotY = randomReal(-maxR, maxR);
  const Real rotZ = randomReal(-maxR, maxR);

  Real** rBCoords = GPUCopy::rollBackCoordinatesPtr();
  Real** aCoords = GPUCopy::atomCoordinatesPtr();
  Real* bSize = GPUCopy::sizePtr();
  int* pIdxes = GPUCopy::primaryIndexesPtr();
  int** molData = GPUCopy::moleculeDataPtr();

  // Do the move here
  #pragma acc parallel loop deviceptr(aCoords, rBCoords) \
      if (on_gpu)
  for (int i = 0; i < molLen; i++) {
    for (int j = 0; j < NUM_DIMENSIONS; j++) {
      rBCoords[j][i] = aCoords[j][molStart + i];
    }
    if (i == vertexIdx)
      continue;
    rotateAtom(molStart + i, molStart + vertexIdx, rotX, rotY, rotZ, aCoords);
    translateAtom(molStart + i, deltaX, deltaY, deltaZ, aCoords);
  }

  #pragma acc parallel loop deviceptr(aCoords, molData, pIdxes, bSize) \
      if (on_gpu)
  for (int i = 0; i < 1; i++) {
    aCoords[0][molStart + vertexIdx] += deltaX;
    aCoords[1][molStart + vertexIdx] += deltaY;
    aCoords[2][molStart + vertexIdx] += deltaZ;
    keepMoleculeInBox(molIdx, aCoords, molData, pIdxes, bSize);
  }
}

void SimCalcs::intramolecularMove(int molIdx, bool verbose) {
  // Save the molecule data for rolling back
  // TODO (blm): Put these in the GPU with GPUCopy
  saveBonds(molIdx);
  saveAngles(molIdx);
  // Max with one to avoid divide by zero if no intra moves
  int numMoveTypes = max(ENABLE_BOND + ENABLE_ANGLE + ENABLE_DIHEDRAL, 1);
  Real intraScaleFactor = 0.25 + (0.75 / (Real)(numMoveTypes));
  Real scaleFactor;
  std::set<int> indexes;

  Real newEnergy = 0, currentEnergy = calcIntraMolecularEnergy(molIdx, false);

  // TODO (blm): allow max to be configurable
  int numBonds = sb->moleculeData[MOL_BOND_COUNT][molIdx];
  int numAngles = sb->moleculeData[MOL_ANGLE_COUNT][molIdx];
  Real bondDelta = sb->maxBondDelta, angleDelta = sb->maxAngleDelta;

  // Handle bond moves
  if (ENABLE_BOND) {
    int numBondsToMove = sb->moleculeData[MOL_BOND_COUNT][molIdx];
    if (numBondsToMove > 3) {
      numBondsToMove = (int)randomReal(2, numBonds);
      numBondsToMove = min(numBondsToMove, sb->maxIntraMoves);
    }
    scaleFactor = 0.25 + (0.75 / (Real)numBondsToMove) * intraScaleFactor;
    sb->numBondMoves += numBondsToMove;

    // Select the indexes of the bonds to move
    while (indexes.size() < numBondsToMove) {
      indexes.insert((int)randomReal(0, numBonds));
    }

    // Move and test each bond
    for (auto bondIdx = indexes.begin(); bondIdx != indexes.end(); bondIdx++) {
      Real stretchDist = scaleFactor * randomReal(-bondDelta, bondDelta);
      // DEBUG
      if (verbose && VERBOSE) {
        std::cout << "Changing bond " << *bondIdx << " by " << stretchDist << std::endl;
      }
      stretchBond(molIdx, *bondIdx, stretchDist);

    }
    // Do an MC test for delta tuning
    // Note: Failing does NOT mean we rollback
    newEnergy = calcIntraMolecularEnergy(molIdx, false);
    if (SimCalcs::acceptMove(currentEnergy, newEnergy)) {
      sb->numAcceptedBondMoves += numBondsToMove;
    }
    currentEnergy = newEnergy;
    indexes.clear();
  }

  // Handle angle movements
  if (ENABLE_ANGLE) {
    int numAnglesToMove = sb->moleculeData[MOL_ANGLE_COUNT][molIdx];
    if (numAnglesToMove > 3) {
      numAnglesToMove = (int)randomReal(2, numAngles);
      numAnglesToMove = min(numAnglesToMove, sb->maxIntraMoves);
    }
    scaleFactor = 0.25 + (0.75 / (Real)numAnglesToMove) * intraScaleFactor;
    sb->numAngleMoves += numAnglesToMove;

    // Select the indexes of the bonds to move
    while (indexes.size() < numAnglesToMove) {
      indexes.insert((int)randomReal(0, numAngles));
    }

    // Move and test each angle
    for (auto angle = indexes.begin(); angle != indexes.end(); angle++) {
      Real expandDist = scaleFactor * randomReal(-angleDelta, angleDelta);
      // DEBUG
      if (verbose && VERBOSE) {
        std::cout << "Changing angle " << *angle << " by " << expandDist << std::endl;
      }
      expandAngle(molIdx, *angle, expandDist);
    }
    // Do an MC test for delta tuning
    // Note: Failing does NOT mean we rollback
    newEnergy = calcIntraMolecularEnergy(molIdx, false);
    if (SimCalcs::acceptMove(currentEnergy, newEnergy)) {
      sb->numAcceptedAngleMoves += numAnglesToMove;
    }
    currentEnergy = newEnergy;
    indexes.clear();
  }

  // TODO: Put dihedral movements here

  // Tweak the deltas to acheive 40% intramolecular acceptance ratio
  // FIXME: Make interval configurable
  if (ENABLE_TUNING && sb->stepNum != 0 && (sb->stepNum % 1000) == 0) {
    Real bondRatio = (Real)sb->numAcceptedBondMoves / sb->numBondMoves;
    Real angleRatio = (Real)sb->numAcceptedAngleMoves / sb->numAngleMoves;
    Real diff;

    diff = bondRatio - TARGET_RATIO;
    if (fabs(diff) > RATIO_MARGIN) {
      sb->maxBondDelta += sb->maxBondDelta * diff;
    }
    diff = angleRatio - TARGET_RATIO;
    if (fabs(angleDelta) > RATIO_MARGIN) {
      sb->maxAngleDelta += sb->maxAngleDelta * diff;
    }

    // Reset the ratio values
    sb->numAcceptedBondMoves = 0;
    sb->numBondMoves = 0;
    sb->numAcceptedAngleMoves = 0;
    sb->numAngleMoves = 0;
  }

  // DEBUG
  if (verbose && VERBOSE) {
    std::cout << std::endl;
  }
}

void SimCalcs::saveBonds(int molIdx) {
  int** moleculeData = GPUCopy::moleculeDataPtr();
  Real* bondLengths = GPUCopy::bondsPtr();
  Real* rbBondLengths = GPUCopy::rollBackBondsPtr();
  int start = moleculeData[MOL_BOND_START][molIdx];
  int count = moleculeData[MOL_BOND_COUNT][molIdx];

  for (int i = 0; i < count; i++) {
    rbBondLengths[i + start] = bondLengths[i + start];
  }
}

void SimCalcs::saveAngles(int molIdx) {
  int** moleculeData = GPUCopy::moleculeDataPtr();
  Real* angleSizes = GPUCopy::anglesPtr();
  Real* rbAngleSizes = GPUCopy::rollBackAnglesPtr();
  int start = moleculeData[MOL_ANGLE_START][molIdx];
  int count = moleculeData[MOL_ANGLE_COUNT][molIdx];

  for (int i = 0; i < count; i++) {
    rbAngleSizes[i + start] = angleSizes[i + start];
  }
}

void SimCalcs::translateAtom(int aIdx, Real dX, Real dY, Real dZ,
                             Real** aCoords) {
  aCoords[X_COORD][aIdx] += dX;
  aCoords[Y_COORD][aIdx] += dY;
  aCoords[Z_COORD][aIdx] += dZ;
}

void SimCalcs::keepMoleculeInBox(int molIdx, Real** aCoords, int** molData,
                                 int* pIdxes, Real* bSize) {
  int start = molData[MOL_START][molIdx];
  int end = start + molData[MOL_LEN][molIdx];
  int pIdx = pIdxes[molData[MOL_PIDX_START][molIdx]];

  for (int i = 0; i < NUM_DIMENSIONS; i++) {
    if (aCoords[i][pIdx] < 0) {
      #pragma acc loop independent 
      for (int j = start; j < end; j++) {
        aCoords[i][j] += bSize[i];
      }
    } else if (aCoords[i][pIdx] > bSize[i]) {
      #pragma acc loop independent
      for (int j = start; j < end; j++) {
        aCoords[i][j] -= bSize[i];
      }
    }
  }
}

void SimCalcs::rollback(int molIdx) {
  int molStart = sb->moleculeData[MOL_START][molIdx];
  int molLen = sb->moleculeData[MOL_LEN][molIdx];

  Real** aCoords = GPUCopy::atomCoordinatesPtr();
  Real** rBCoords = GPUCopy::rollBackCoordinatesPtr();

  #pragma acc parallel loop deviceptr(aCoords, rBCoords) if (on_gpu)
  for (int i = 0; i < NUM_DIMENSIONS; i++) {
    #pragma acc loop independent 
    for (int j = 0; j < molLen; j++) {
      aCoords[i][molStart + j] = rBCoords[i][j];
    }
  }

  rollbackAngles(molIdx);
  rollbackBonds(molIdx);
}

void SimCalcs::rollbackBonds(int molIdx) {
  int** moleculeData = GPUCopy::moleculeDataPtr();
  Real* bondLengths = GPUCopy::bondsPtr();
  Real* rbBondLengths = GPUCopy::rollBackBondsPtr();
  int start = moleculeData[MOL_BOND_START][molIdx];
  int count = moleculeData[MOL_BOND_COUNT][molIdx];

  for (int i = 0; i < count; i++) {
    bondLengths[i + start] = rbBondLengths[i + start];
  }
}

void SimCalcs::rollbackAngles(int molIdx) {
  int** moleculeData = GPUCopy::moleculeDataPtr();
  Real* angleSizes = GPUCopy::anglesPtr();
  Real* rbAngleSizes = GPUCopy::rollBackAnglesPtr();
  int start = moleculeData[MOL_ANGLE_START][molIdx];
  int count = moleculeData[MOL_ANGLE_COUNT][molIdx];

  for (int i = 0; i < count; i++) {
    angleSizes[i + start] = rbAngleSizes[i + start];
  }
}

void SimCalcs::unionAtoms(int atom1, int atom2) {
  int a1Parent = find(atom1);
  int a2Parent = find(atom2);
  if (a1Parent != a2Parent) {
    sb->unionFindParent[a1Parent] = a2Parent;
  }
}

int SimCalcs::find(int atomIdx) {
  if (sb->unionFindParent[atomIdx] == atomIdx) {
    return atomIdx;
  } else {
    sb->unionFindParent[atomIdx] = find(sb->unionFindParent[atomIdx]);
    return sb->unionFindParent[atomIdx];
  }
}

bool SimCalcs::acceptMove(Real oldEnergy, Real newEnergy) {
    // Always accept decrease in energy
    if (newEnergy < oldEnergy) {
      return true;
    }

    // Otherwise use random number to determine weather to accept
    return exp(-(newEnergy - oldEnergy) / sb->kT) >=
        randomReal(0.0, 1.0);
}

void SimCalcs::setSB(SimBox* sb_in) {
  sb = sb_in;
  on_gpu = GPUCopy::onGpu();
}
