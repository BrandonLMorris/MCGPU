/**
 * Base class for an iteration of the simulation.
 *
 * Contains logic common to progressing the simulation, regardless of the
 * particular strategy employed by the configuration.
 */

#ifndef METROPOLIS_SIMULATIONSTEP_H
#define METROPOLIS_SIMULATIONSTEP_H

#include "SimBox.h"
#include "Metropolis/Utilities/MathLibrary.h"

class SimulationStep {
 public:
  /** Construct a new SimulationStep object from a SimBox pointer */
  SimulationStep(SimBox *box);

  /**
   * Returns the index of a random molecule within the simulation box.
   * @return A random integer from 0 to (numMolecules - 1)
   */
  int chooseMolecule(SimBox *box);


  /**
   * Determines the energy contribution of a particular molecule.
   *
   * @param currMol The index of the molecule to calculate the contribution of.
   * @param startMol The index of the molecule to begin searching from to
   *        determine interaction energies.
   * @return The total energy of the box (discounts initial lj / charge energy)
   */
  virtual Real calcMolecularEnergyContribution(int currMol, int startMol) = 0;


  /**
   * Randomly moves the molecule within the box. This performs a translation
   * and a rotation, and saves the old position.
   *
   * @param molIdx The index of the molecule to change.
   */
  virtual void changeMolecule(int molIdx, SimBox *box);


  /**
   * Move a molecule back to its original poisition. Performs translation and
   * rotation.
   *
   * @param molIdx The index of the molecule to change.
   */
  virtual void rollback(int molIdx, SimBox *box);


  /**
   * Determines the total energy of the box
   *
   * @param subLJ Initial Lennard - Jones energy.
   * @param subCharge Initial Coulomb energy.
   * @return The total energy of the box.
   */
  virtual Real calcSystemEnergy(Real &subLJ, Real &subCharge, int numMolecules);
};

/**
 * SimCalcs namespace
 *
 * Contains logic for caclulations consumed by the SimulationStep class.
 * Although logically related to the SimulationStep class, must be separated
 * out to a namespace to acurrately run on the GPU.
 */
namespace SimCalcs {
  extern SimBox* sb;
  extern int on_gpu;

  /**
   * Determines whether or not two molecule's primaryIndexes are within the
   * cutoff range of one another.
   *
   * @param p1Start The index of the first primary index from molecule 1.
   * @param p1End index of the last primary index from molecule 1,  + 1.
   * @param p2Start index of the first primary index from molecule 2.
   * @param p2End index of the last primary index from molecule 2,  + 1.
   * @param atomCoords The coordinates of the atoms to check.
   * @return true if the molecules are in range, false otherwise.
   */
  #pragma acc routine seq
  bool moleculesInRange(int p1Start, int p1End, int p2Start, int p2End,
                        Real** atomCoords, Real* bSize, int* primaryIndexes,
                        Real cutoff);

  /**
   * Calculates the square of the distance between two atoms.
   *
   * @param a1 The atom index of the first atom.
   * @param a2 The atom index of the second atom.
   * @return The square of the distance between the atoms.
   */
  #pragma acc routine seq
  Real calcAtomDistSquared(int a1, int a2, Real** aCoords,
                           Real* bSize);

  /**
   * Calculates the Lennard - Jones potential between two atoms.
   *
   * @param a1  The atom index of the first atom.
   * @param a2  The atom index of the second atom.
   * @param r2  The distance between the atoms, squared.
   * @return The Lennard - Jones potential from the two atoms' interaction.
   */
  #pragma acc routine seq
  Real calcLJEnergy(int a1, int a2, Real r2, Real** aData);

  /**
   * Given a distance, makes the distance periodic to mitigate distances
   * greater than half the length of the box.
   *
   * @param x The measurement to make periodic.
   * @param dimension The dimension the measurement must be made periodic in.
   * @return The measurement, scaled to be periodic.
   */
  #pragma acc routine seq
  Real makePeriodic(Real x, int dimension, Real* bSize);

  /**
   * Calculates the Coloumb potential between two atoms.
   *
   * @param a1 The atom index of the first atom.
   * @param a2 The atom index of the second atom.
   * @param r  The distance between the atoms.
   * @return The Coloumb potential from the two atoms' interaction.
   */
  #pragma acc routine seq
  Real calcChargeEnergy(int a1, int a2, Real r, Real** aData);

  /**
   * Calculates the geometric mean of two real numbers.
   *
   * @param a The first real number.
   * @param b The second real number.
   * @return sqrt(|a*b|), the geometric mean of the two numbers.
   */
  #pragma acc routine seq
  Real calcBlending (Real a, Real b);

  /**
   * Given a molecule to change, randomly moves the molecule within the box.
   * This performs a translation and a rotation, and saves the old position.
   *
   * @param molIdx The index of the molecule to change.
   */
  void changeMolecule(int molIdx);

  /**
   * Keeps a molecule in the simulation box's boundaries, based on the location
   * of its first primary index atom.
   *
   * @param molIdx The index of the molecule to keep inside the box.
   */
  #pragma acc routine seq
  void keepMoleculeInBox(int molIdx, Real** aCoords, int** molData,
                         int* pIdxes, Real* bsize);


  /**
   * Given an atom to translate, and the directions to tranlate it, moves it.
   *
   * @param aIdx The index of the atom to change.
   * @param dX The amount to translate in the x direction.
   * @param dY The amount to translate in the y direction.
   * @param dZ The amount to tranlsate in the z direction.
   */
  #pragma acc routine seq
  void translateAtom(int aIdx, Real dX, Real dY, Real dZ, Real** aCoords);

  /**
   * Given an atom to rotate, its pivot point, and the amounts to rotate,
   * rotates the atom around the pivot (rotations in degrees).
   *
   * @param aIdx The index of the atom to change.
   * @param pivotIdx The index of the atom about which to rotate.
   * @param rotX The amount of rotation around the x-axis that is done.
   * @param rotY The amount of rotation around the y-axis that is done.
   * @param rotZ The amount of rotation around the z-axis that is done.
   */
  #pragma acc routine seq
  void rotateAtom(int aIdx, int pivotIdx, Real rotX, Real rotY, Real rotZ,
                  Real** aCoords);

  /**
   * Given an atom and an amount to rotate, rotates about the x-axis.
   *
   * @param aIdx The index of the atom to rotate.
   * @param angleDeg The angle to rotate it (in degrees).
   */
  #pragma acc routine seq
  void rotateX(int aIdx, Real angleDeg, Real** aCoords);

  /**
   * Given an atom and an amount to rotate, rotates it about the y-axis.
   *
   * @param aIdx The index of the atom to rotate.
   * @param angleDeg The angle to rotate it (in degrees).
   */
  #pragma acc routine seq
  void rotateY(int aIdx, Real angleDeg, Real** aCoords);

  /**
   * Given an atom and an amount to rotate, rotates it about the z-axis.
   *
   * @param aIdx The index of the atom to rotate.
   * @param angleDeg The angle to rotate it (in degrees).
   */
  #pragma acc routine seq
  void rotateZ(int aIdx, Real angleDeg, Real** aCoords);

  /**
   * Roll back a molecule to its original poisition. Performs translation and
   * rotation.
   *
   * @param molIdx The index of the molecule to change.
   */
  void rollback(int molIdx);

  /** Set the current SimBox instance for this namespace */
  void setSB(SimBox* sb);
}

#endif
