# -*- Mode: python; tab-width: 4; indent-tabs-mode:nil; -*-
# vim: tabstop=4 expandtab shiftwidth=4 softtabstop=4
#
# MDAnalysis --- https://www.mdanalysis.org
# Copyright (c) 2006-2017 The MDAnalysis Development Team and contributors
# (see the file AUTHORS for the full list of names)
#
# Released under the GNU Public Licence, v2 or any higher version
#
# Please cite your use of MDAnalysis in published work:
#
# R. J. Gowers, M. Linke, J. Barnoud, T. J. E. Reddy, M. N. Melo, S. L. Seyler,
# D. L. Dotson, J. Domanski, S. Buchoux, I. M. Kenney, and O. Beckstein.
# MDAnalysis: A Python package for the rapid analysis of molecular dynamics
# simulations. In S. Benthall and S. Rostrup editors, Proceedings of the 15th
# Python in Science Conference, pages 102-109, Austin, TX, 2016. SciPy.
# doi: 10.25080/majora-629e541a-00e
#
# N. Michaud-Agrawal, E. J. Denning, T. B. Woolf, and O. Beckstein.
# MDAnalysis: A Toolkit for the Analysis of Molecular Dynamics Simulations.
# J. Comput. Chem. 32 (2011), 2319--2327, doi:10.1002/jcc.21787
#
#

import cython 
import weakref
from cpython.weakref cimport PyWeakref_NewRef
import warnings
import copy
import numbers

import numpy as np
cimport numpy as cnp
cnp.import_array()

from libc.stdint cimport int64_t, uint64_t
from libcpp cimport bool

from . import core
from .. import NoDataError
from .. import (
    _READERS, _READER_HINTS,
    _SINGLEFRAME_WRITERS,
    _MULTIFRAME_WRITERS,
    _CONVERTERS
)
from .. import units
from ..auxiliary.base import AuxReader
from ..auxiliary.core import auxreader
from ..lib.util import asiterable, Namespace

"""\
Timestep Class --- :mod:`MDAnalysis.coordinates.timestep`
===================================================

Derive other Timestep, classes from the classes in this module.
The derived classes must follow the :ref:`Trajectory API`.

Timestep
--------

A :class:`Timestep` holds information for the current time frame in
the trajectory. It is one of the central data structures in
MDAnalysis.

.. class:: Timestep

   .. automethod:: __init__
   .. automethod:: from_coordinates
   .. automethod:: from_timestep
   .. autoattribute:: n_atoms
   .. attribute::`frame`

      frame number (0-based)

      .. versionchanged:: 0.11.0
         Frames now 0-based; was 1-based

   .. autoattribute:: time
   .. autoattribute:: dt
   .. autoattribute:: positions
   .. autoattribute:: velocities
   .. autoattribute:: forces
   .. autoattribute:: has_positions
   .. autoattribute:: has_velocities
   .. autoattribute:: has_forces
   .. attribute:: _pos

      :class:`numpy.ndarray` of dtype :class:`~numpy.float32` of shape
      (*n_atoms*, 3) and internal FORTRAN order, holding the raw
      cartesian coordinates (in MDAnalysis units, i.e. Å).

      .. Note::

         Normally one does not directly access :attr:`_pos` but uses
         the :meth:`~MDAnalysis.core.groups.AtomGroup.coordinates`
         method of an :class:`~MDAnalysis.core.groups.AtomGroup` but
         sometimes it can be faster to directly use the raw
         coordinates. Any changes to this array are immediately
         reflected in atom positions. If the frame is written to a new
         trajectory then the coordinates are changed. If a new
         trajectory frame is loaded, then *all* contents of
         :attr:`_pos` are overwritten.

   .. attribute:: _velocities

      :class:`numpy.ndarray` of dtype :class:`~numpy.float32`. of shape
      (*n_atoms*, 3), holding the raw velocities (in MDAnalysis
      units, i.e. typically Å/ps).

      .. Note::

         Normally velocities are accessed through the
         :attr:`velocities` or the
         :meth:`~MDAnalysis.core.groups.AtomGroup.velocities`
         method of an :class:`~MDAnalysis.core.groups.AtomGroup`

         :attr:`~Timestep._velocities` only exists if the :attr:`has_velocities`
         flag is True

      .. versionadded:: 0.7.5

   .. attribute:: _forces

      :class:`numpy.ndarray` of dtype :class:`~numpy.float32`. of shape
      (*n_atoms*, 3), holding the forces

      :attr:`~Timestep._forces` only exists if :attr:`has_forces`
      is True

      .. versionadded:: 0.11.0
         Added as optional to :class:`Timestep`

   .. autoattribute:: dimensions
   .. autoattribute:: triclinic_dimensions
   .. autoattribute:: volume
   .. attribute:: data

      :class:`dict` that holds arbitrary per Timestep data

      .. versionadded:: 0.11.0

   .. automethod:: __getitem__
   .. automethod:: __eq__
   .. automethod:: __iter__
   .. automethod:: copy
   .. automethod:: copy_slice

"""

cdef class Timestep:
    """Timestep data for one frame

    :Methods:

      ``ts = Timestep(n_atoms)``

         create a timestep object with space for n_atoms


    .. versionchanged:: 0.11.0
       Added :meth:`from_timestep` and :meth:`from_coordinates` constructor
       methods.
       :class:`Timestep` init now only accepts integer creation.
       :attr:`n_atoms` now a read only property.
       :attr:`frame` now 0-based instead of 1-based.
       Attributes `status` and `step` removed.
    .. versionchanged:: 2.0.0
       Timestep now can be (un)pickled. Weakref for Reader
       will be dropped.
       Timestep now stores in to numpy array memory in 'C' order rather than
       'F' (Fortran).
    .. versionchanged::
    """

    order = 'C'

    cdef uint64_t _n_atoms
    cdef public int64_t  frame
    # no longer optional
    cdef public int64_t  _frame  


    cdef bool _has_positions
    cdef bool _has_velocities
    cdef bool _has_forces

    # these have to be public for testing
    cdef public cnp.ndarray _unitcell 
    cdef public cnp.ndarray _pos
    cdef public cnp.ndarray _velocities
    cdef public cnp.ndarray _forces

    cdef object _dtype
    cdef public dict data
    cdef public object  _reader
    cdef public object aux




    def __cinit__(self, uint64_t n_atoms, dtype=np.float32, **kwargs):
        # c++ level objects
        self._n_atoms =  n_atoms
        self.frame = -1
        # init of _frame no longer optional
        self._frame = -1

        self._has_positions = False
        self._has_velocities = False
        self._has_forces = False

        self._unitcell = np.zeros(6, dtype=dtype)
        self._pos = np.empty(shape=(n_atoms,3), dtype=dtype)
        self._velocities = np.empty(shape=(n_atoms,3), dtype=dtype)
        self._forces = np.empty(shape=(n_atoms,3), dtype=dtype)

    def __init__(self, uint64_t n_atoms, dtype=np.float32, **kwargs):
        #python objects
        self._dtype = dtype
        self.data = {}

        for att in ('dt', 'time_offset'):
            try:
                self.data[att] = kwargs[att]
            except KeyError:
                pass
        try:
            # do I have a hook back to the Reader?
            # can possibly __cinit__ this with PyWeakRefNew
            self._reader = weakref.ref(kwargs['reader'])
        except KeyError:
            pass

        self.has_positions = kwargs.get('positions', True)
        self.has_velocities = kwargs.get('velocities', False)
        self.has_forces = kwargs.get('forces', False)

        # set up aux namespace for adding auxiliary data
        self.aux = Namespace()
        
    
    def __dealloc__(self):
            pass


    @property
    def n_atoms(self):
        """A read only view of the number of atoms this Timestep has

        .. versionchanged:: 0.11.0
           Changed to read only property
        """
        # In future could do some magic here to make setting n_atoms
        # resize the coordinate arrays, but
        # - not sure if that is ever useful
        # - not sure how to manage existing data upon extension
        return self._n_atoms

    @property
    def dtype(self):
        return self._dtype


    @property
    def has_positions(self):
        return self._has_positions

    @has_positions.setter
    def has_positions(self, val):
        if val and not self._has_positions:
            # Setting this will always reallocate position data
            # ie
            # True -> False -> True will wipe data from first True state
            self._pos = np.zeros((self.n_atoms, 3), dtype=self.dtype,
                                 order=self.order)
            self._has_positions = True
        elif not val:
            # Unsetting val won't delete the numpy array
            self._has_positions = False

    
    @property
    def has_velocities(self):
        return self._has_velocities

    @has_velocities.setter
    def has_velocities(self, val):
        if val and not self._has_velocities:
            # Setting this will always reallocate velocity data
            # ie
            # True -> False -> True will wipe data from first True state
            self._velocities = np.zeros((self.n_atoms, 3), dtype=self.dtype,
                                 order=self.order)
            self._has_velocities = True
        elif not val:
            # Unsetting val won't delete the numpy array
            self._has_velocities = False
    
    @property
    def has_forces(self):
        return self._has_forces

    @has_forces.setter
    def has_forces(self, val):
        if val and not self._has_forces:
            # Setting this will always reallocate force data
            # ie
            # True -> False -> True will wipe data from first True state
            self._forces = np.zeros((self.n_atoms, 3), dtype=self.dtype,
                                 order=self.order)
            self._has_forces = True
        elif not val:
            # Unsetting val won't delete the numpy array
            self._has_forces = False


    @property
    def positions(self):
        if self._has_positions:
            return self._pos
        else:
            raise NoDataError("This Timestep has no position information")

 
    @positions.setter
    def positions(self, new_positions):
        # force C contig memory order
        cdef int flag = 0
        flag = cnp.PyArray_IS_C_CONTIGUOUS(new_positions)
        if not flag:
            raise TypeError("Input array is not C-style contiguous")
        self._has_positions = True
        self._pos = new_positions


    @property
    def _x(self):
        """A view onto the x dimension of position data

        .. versionchanged:: 0.11.0
           Now read only
        """
        return self.positions[:, 0]

    @property
    def _y(self):
        """A view onto the y dimension of position data

        .. versionchanged:: 0.11.0
           Now read only
        """
        return self.positions[:, 1]

    @property
    def _z(self):
        """A view onto the z dimension of position data

        .. versionchanged:: 0.11.0
           Now read only
        """
        return self.positions[:, 2]

    @property
    def dimensions(self):
        """View of unitcell dimensions (*A*, *B*, *C*, *alpha*, *beta*, *gamma*)

        lengths *a*, *b*, *c* are in the MDAnalysis length unit (Å), and
        angles are in degrees.
        """
        if (self._unitcell[:3] == 0).all():
            return None
        else:
            return self._unitcell

    @dimensions.setter
    def dimensions(self,  new_dimensions):
        cdef int flag = 0
        if new_dimensions is None:
            self._unitcell[:] = 0
        else:
            # force C contig memory order
            flag = cnp.PyArray_IS_C_CONTIGUOUS(new_dimensions)
            if not flag:
                raise TypeError("Input array is not C-style contiguous")
            self._unitcell = new_dimensions

    
    @property
    def volume(self):
        """volume of the unitcell"""
        if self.dimensions is None:
            return 0
        else:
            return core.box_volume(self.dimensions)

    @property
    def triclinic_dimensions(self):
        """The unitcell dimensions represented as triclinic vectors

        Returns
        -------
        numpy.ndarray
             A (3, 3) numpy.ndarray of unit cell vectors

        Examples
        --------
        The unitcell for a given system can be queried as either three
        vectors lengths followed by their respective angle, or as three
        triclinic vectors.

          >>> ts.dimensions
          array([ 13.,  14.,  15.,  90.,  90.,  90.], dtype=float32)
          >>> ts.triclinic_dimensions
          array([[ 13.,   0.,   0.],
                 [  0.,  14.,   0.],
                 [  0.,   0.,  15.]], dtype=float32)

        Setting the attribute also works::

          >>> ts.triclinic_dimensions = [[15, 0, 0], [5, 15, 0], [5, 5, 15]]
          >>> ts.dimensions
          array([ 15.        ,  15.81138802,  16.58312416,  67.58049774,
                  72.45159912,  71.56504822], dtype=float32)

        See Also
        --------
        :func:`MDAnalysis.lib.mdamath.triclinic_vectors`


        .. versionadded:: 0.11.0
        """
        if self.dimensions is None:
            return None
        else:
            return core.triclinic_vectors(self.dimensions)

    @triclinic_dimensions.setter
    def triclinic_dimensions(self, new_dimensions):
        """Set the unitcell for this Timestep as defined by triclinic vectors

        .. versionadded:: 0.11.0
        """
        cdef int flag = 0

        if new_dimensions is None:
            self.dimensions = None
        else:
            # force C contig memory order
            flag = cnp.PyArray_IS_C_CONTIGUOUS(new_dimensions)
            if not flag:
                raise TypeError("Input array is not C-style contiguous")
            self.dimensions = core.triclinic_box(*new_dimensions)

    @property
    def velocities(self):
        if self._has_velocities:
            return self._velocities
        else:
            raise NoDataError("This Timestep has no velocities information")


 
    @velocities.setter
    def velocities(self,  new_velocities):
        # force C contig memory order
        self._has_velocities = True
        self._velocities = new_velocities


    @property
    def forces(self):
        if self._has_forces:
          return self._forces
        else:
            raise NoDataError("This Timestep has no force information")


 
    @forces.setter
    def forces(self,  new_forces):
        # force C contig memory order
        cdef int flag
        flag = cnp.PyArray_IS_C_CONTIGUOUS(new_forces)
        if not flag:
            raise TypeError("Input array is not C-style contiguous")
        self._has_forces = True
        self._forces = new_forces



    @classmethod
    def from_timestep(cls, Timestep other, **kwargs):
        """Create a copy of another Timestep, in the format of this Timestep

        .. versionadded:: 0.11.0
        """
        ts = cls(other.n_atoms,
                 positions=other.has_positions,
                 velocities=other.has_velocities,
                 forces=other.has_forces,
                 **kwargs)
        ts.frame = other.frame
        if  other.dimensions is not None:
            ts.dimensions = other.dimensions.copy(order=cls.order)
        try:
            ts.positions = other.positions.copy(order=cls.order)
        except NoDataError:
            pass
        try:
            ts.velocities = other.velocities.copy(order=cls.order)
        except NoDataError:
            pass
        try:
            ts.forces = other.forces.copy(order=cls.order)
        except NoDataError:
            pass

        # Optional attributes that don't live in .data
        # should probably iron out these last kinks
        for att in ('_frame',):
            try:
                setattr(ts, att, getattr(other, att))
            except AttributeError:
                pass

        try:
            other._reader = weakref.ref(ts._reader())
        except TypeError: # TypeError from calling None weakref
            pass
            
        ts.data = copy.deepcopy(other.data)

        return ts

    @classmethod
    def from_coordinates(cls,
                         positions=None,
                         velocities=None,
                         forces=None,
                         **kwargs):
        """Create an instance of this Timestep, from coordinate data

        Can pass position, velocity and force data to form a Timestep.

        .. versionadded:: 0.11.0
        """
        has_positions = positions is not None
        has_velocities = velocities is not None
        has_forces = forces is not None

        lens = [len(a) for a in [positions, velocities, forces]
                if a is not None]
        if not lens:
            raise ValueError("Must specify at least one set of data")
        n_atoms = max(lens)
        # Check arrays are matched length?
        if not all(val == n_atoms for val in lens):
            raise ValueError("Lengths of input data mismatched")

        ts = cls(n_atoms,
                 positions=has_positions,
                 velocities=has_velocities,
                 forces=has_forces,
                 **kwargs)
        if has_positions:
            ts.positions = positions
        if has_velocities:
            ts.velocities = velocities
        if has_forces:
            ts.forces = forces

        return ts


    def __eq__(self, other):
        """Compare with another Timestep

        .. versionadded:: 0.11.0
        """
        if not isinstance(other, Timestep):
            return False

        if not self.frame == other.frame:
            return False

        if not self.n_atoms == other.n_atoms:
            return False

        if not self.has_positions == other.has_positions:
            return False
        if self.has_positions:
            if not (self.positions == other.positions).all():
                return False

        if self.dimensions is None:
            if other.dimensions is not None:
                return False
        else:
            if other.dimensions is None:
                return False
            if not (self.dimensions == other.dimensions).all():
                return False

        if not self.has_velocities == other.has_velocities:
            return False
        if self.has_velocities:
            if not (self.velocities == other.velocities).all():
                return False

        if not self.has_forces == other.has_forces:
            return False
        if self.has_forces:
            if not (self.forces == other.forces).all():
                return False

        return True

    def __ne__(self, other):
        return not self == other

    def __getitem__(self, atoms):
        """Get a selection of coordinates

        ``ts[i]``

           return coordinates for the i'th atom (0-based)

        ``ts[start:stop:skip]``

           return an array of coordinates, where start, stop and skip
           correspond to atom indices,
           :attr:`MDAnalysis.core.groups.Atom.index` (0-based)
        """
        if isinstance(atoms, numbers.Integral):
            return self._pos[atoms]
        elif isinstance(atoms, (slice, np.ndarray)):
            return self._pos[atoms]
        else:
            raise TypeError

    def __getattr__(self, attr):
        # special-case timestep info
        if attr in ('velocities', 'forces', 'positions'):
            raise NoDataError('This Timestep has no ' + attr)
        err = "{selfcls} object has no attribute '{attr}'"
        raise AttributeError(err.format(selfcls=type(self).__name__,
                                        attr=attr))

    def __len__(self):
        return self.n_atoms

    def __iter__(self):
        """Iterate over coordinates

        ``for x in ts``

            iterate of the coordinates, atom by atom
        """
        for i in range(self.n_atoms):
            yield self[i]

    def __repr__(self):
        desc = "< Timestep {0}".format(self.frame)
        try:
            tail = " with unit cell dimensions {0} >".format(self.dimensions)
        except NotImplementedError:
            tail = " >"
        return desc + tail

    def copy(self):
        """Make an independent ("deep") copy of the whole :class:`Timestep`."""
        return self.__deepcopy__()

    def __deepcopy__(self):
        return self.from_timestep(self)

    # cython classes don't have the __dict__ attribute and we use __cinit__ 
    # meaning we don't get a default __reduce__ implementation
    # so we need to  implement __getstate__ __setstate__ and friends

    def __getnewargs_ex__(self):
        return (self.n_atoms,),{"dtype":self.dtype}

    def __getstate__(self):
        state = {
            "frame" : self.frame,
            "_n_atoms" : self._n_atoms,
            "_frame" : self._frame, 
            "_has_positions" : self._has_positions,
            "_has_velocities" : self._has_velocities,
            "_has_forces" : self._has_forces,

            "_unitcell"  : self._unitcell,
            "_pos" : self._pos,
            "_velocities" : self._velocities,
            "_forces" : self._forces,

            "_dtype" : self._dtype,
            "data" : self.data,
            "aux" : self.aux,
            "dt" : self.dt
        }
        return state

    def __setstate__(self, state):
        self.frame = state["frame"]
        self._n_atoms = state["_n_atoms"]
        self._frame = state["_frame"] 
        self.has_positions = state["_has_positions"]
        self._has_velocities = state["_has_velocities"]
        self._has_forces = state["_has_forces"]
        self._unitcell = state["_unitcell"]
        self._pos = state["_pos"]
        self._velocities = state["_velocities"]
        self._forces = state["_forces"]
        self._dtype = state["_dtype"] 
        self.data = state["data"]
        self.aux = state["aux"]

    def copy_slice(self, sel):
        """Make a new `Timestep` containing a subset of the original `Timestep`.

        Parameters
        ----------
        sel : array_like or slice
            The underlying position, velocity, and force arrays are sliced
            using a :class:`list`, :class:`slice`, or any array-like.

        Returns
        -------
        :class:`Timestep`
            A `Timestep` object of the same type containing all header
            information and all atom information relevant to the selection.

        Note
        ----
        The selection must be a 0 based :class:`slice` or array of the atom indices
        in this :class:`Timestep`

        Example
        -------
        Using a Python :class:`slice` object::

           new_ts = ts.copy_slice(slice(start, stop, step))

        Using a list of indices::

           new_ts = ts.copy_slice([0, 2, 10, 20, 23])


        .. versionadded:: 0.8
        .. versionchanged:: 0.11.0
           Reworked to follow new Timestep API.  Now will strictly only
           copy official attributes of the Timestep.

        """
        # Detect the size of the Timestep by doing a dummy slice
        try:
            pos = self.positions[sel, :]
        except NoDataError:
            # It's cool if there's no Data, we'll live
            pos = None
        except Exception:
            errmsg = ("Selection type must be compatible with slicing the "
                      "coordinates")
            raise TypeError(errmsg) from None
        try:
            vel = self.velocities[sel, :]
        except NoDataError:
            vel = None
        except Exception:
            errmsg = ("Selection type must be compatible with slicing the "
                      "coordinates")
            raise TypeError(errmsg) from None
        try:
            force = self.forces[sel, :]
        except NoDataError:
            force = None
        except Exception:
            errmsg = ("Selection type must be compatible with slicing the "
                      "coordinates")
            raise TypeError(errmsg) from None

        new_TS = self.__class__.from_coordinates(
            positions=pos,
            velocities=vel,
            forces=force)

        new_TS.dimensions = self.dimensions

        new_TS.frame = self.frame

        for att in ('_frame',):
            try:
                setattr(new_TS, att, getattr(self, att))
            except AttributeError:
                pass

        try:
            new_TS._reader = weakref.ref(self._reader())
        except TypeError: # TypeError from calling None weakref
            pass
        new_TS.data = copy.deepcopy(self.data)

        return new_TS



    @property
    def dt(self):
        """The time difference in ps between timesteps

        Note
        ----
        This defaults to 1.0 ps in the absence of time data


        .. versionadded:: 0.11.0
        """
        try:
            return self.data['dt']
        except KeyError:
            pass
        try:
            dt = self.data['dt'] = self._reader()._get_dt()
            return dt
        # TypeError from calling None weakref
        # AttributeError from ._get_dt()
        except (TypeError, AttributeError):
            pass
        
        warnings.warn("Reader has no dt information, set to 1.0 ps")
        return 1.0
    
    @dt.setter
    def dt(self, new):
        self.data['dt'] = new

    @dt.deleter
    def dt(self):
        del self.data['dt']

    @property
    def time(self):
        """The time in ps of this timestep

        This is calculated as::

          time = ts.data['time_offset'] + ts.time

        Or, if the trajectory doesn't provide time information::

          time = ts.data['time_offset'] + ts.frame * ts.dt

        .. versionadded:: 0.11.0
        """
        offset = self.data.get('time_offset', 0)
        try:
            return self.data['time'] + offset
        except KeyError:
            return self.dt * self.frame + offset

    @time.setter
    def time(self, new):
        self.data['time'] = new

    @time.deleter
    def time(self):
        del self.data['time']
    