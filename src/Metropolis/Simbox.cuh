/*
	New version of SimBox, including linear and parallel functions
	Minimized to include only Atoms and Molecules

	Author: Nathan Coleman
	Last Changed: February 19, 2014
*/

#ifndef SIMBOX_H
#define SIMBOX_H

#include "Utilities/Opls_Scan.h"
#include "Utilities/Config_Scan.h"
#include "Utilities/metroUtil.h"
#include "Utilities/Zmatrix_Scan.h"
#include "Utilities/State_Scan.h"
//#include "Utilities/IOUtilities.cuh"

extern double randomFloat(const double start, const double end);

class SimBox
{
	//Linear
	private:
		Atom *atomPool;
		Environment *environment;
		Molecule changedMolecule;
		Molecule *molecules;

		//Utility
		int copyMolecule(Molecule *destination, Molecule *source);
		int saveMolecule(int moleculeIndex);

	public:
		int moleculeType;
		Table *table;

		//Constructor & Destructor
		SimBox(Config_Scan configScan);
		~SimBox();

		//Getters
		Atom *getAtoms(){return atomPool;};
		Environment *getEnvironment(){return environment};
		Molecule *getMolecules(){return molecules;};

		//Utility
		void assignAtomPositions(double x, double y, double z, Molecule *molecule, Environment *environment);
		int changeMolecule(int moleculeIndex);
		int chooseMolecule();
		void generateFCCBox(Molecule *molecules, Environment *environment);
		void generatePoints(Molecule *molecules, Environment *environment);
		double getFValue(Atom *atom1, Atom *atom2, Molecule *moelecules, Environemnt *environment);
		int getXFromIndex(int index);
		int getYFromIndex(int index);
		void keepMoleculeInBox(Molecule *molecule, Environment *environment);
		double makePeriodic(double x, double box);
		int rollBack(int moleculeIndex);
		double wrapBox(double x, double box);

		//IO functions
		//Being moved to Utilities directory
};

#endif